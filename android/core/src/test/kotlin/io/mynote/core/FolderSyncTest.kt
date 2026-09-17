package io.mynote.core

import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * An in-memory stand-in for Google Drive.
 *
 * Records every write so tests can assert *which* file a device touched — the
 * central safety property is that a device only ever writes its own.
 */
private class FakeFolder : RemoteFolder {
    override val displayName = "Fake Drive"

    private val files = mutableMapOf<String, ByteArray>()
    private val versions = mutableMapOf<String, String>()
    private var revision = 0
    val writtenNames = mutableListOf<String>()
    val readNames = mutableListOf<String>()
    var failure: RemoteFolderError? = null

    override suspend fun list(): List<RemoteFile> {
        failure?.let { throw RemoteFolderException(it) }
        return files.map { (name, data) ->
            RemoteFile(name, 0L, data.size.toLong(), versions[name] ?: "0")
        }
    }

    override suspend fun read(name: String): ByteArray {
        failure?.let { throw RemoteFolderException(it) }
        readNames += name
        return files[name] ?: throw RemoteFolderException(RemoteFolderError.NotFound(name))
    }

    override suspend fun write(name: String, data: ByteArray) {
        failure?.let { throw RemoteFolderException(it) }
        revision++
        files[name] = data
        versions[name] = revision.toString()
        writtenNames += name
    }

    override suspend fun delete(name: String) {
        files.remove(name)
        versions.remove(name)
    }

    /** Drop a file in as if another device had written it. */
    fun seed(deviceId: String, changes: List<Change>) {
        revision++
        val name = DeviceFile.fileName(deviceId)
        files[name] = DeviceFile(deviceId = deviceId, updatedAt = 0, changes = changes).encoded()
        versions[name] = revision.toString()
    }
}

private fun block(id: String, hlc: String, text: String = "x", deleted: Boolean = false) = Change(
    entity = Entity.BLOCK,
    id = id,
    hlc = hlc,
    deleted = deleted,
    fields = mapOf(
        "note_id" to JsonPrimitive("n1"),
        "order_key" to JsonPrimitive("V"),
        "type" to JsonPrimitive("paragraph"),
        "content" to JsonPrimitive(BlockContent(text = text).encoded()),
    ),
)

/**
 * `<millis hex>-<counter hex>-<device>` — the device id is the clock's node,
 * which is also what decides whose file a record belongs in.
 */
private fun hlc(millis: Long, device: String) = Hlc(millis, 0, device).encoded()

private fun textOf(change: Change) = BlockContent.decode(change.string("content")!!).text

class FolderSyncTest {

    @Test
    fun `writes this device's records into its own file`() = runTest {
        val folder = FakeFolder()
        val sync = FolderSync(InMemoryStore(), "phone", folder)

        sync.record(block("b1", sync.stamp(), text = "hello"))
        val outcome = sync.sync().getOrThrow()

        assertEquals(1, outcome.uploaded)
        assertEquals(listOf("device-phone.json"), folder.writtenNames)
    }

    @Test
    fun `never writes another device's file`() = runTest {
        // This is what removes write conflicts entirely: no file has two writers,
        // so there is nothing to lock and nothing to merge on write.
        val folder = FakeFolder()
        folder.seed("tablet", listOf(block("b9", hlc(500, "tablet"))))

        val sync = FolderSync(InMemoryStore(), "phone", folder)
        sync.record(block("b1", sync.stamp()))
        sync.sync()

        assertTrue(folder.writtenNames.all { it == "device-phone.json" })
    }

    @Test
    fun `merges records another device wrote`() = runTest {
        val store = InMemoryStore()
        val folder = FakeFolder()
        folder.seed("tablet", listOf(block("b1", hlc(1000, "tablet"), text = "from the tablet")))

        val outcome = FolderSync(store, "phone", folder).sync().getOrThrow()

        assertEquals(1, outcome.merged)
        assertEquals("from the tablet", textOf(store.record(Entity.BLOCK, "b1")!!))
    }

    @Test
    fun `the newer clock wins when two devices edited the same block`() = runTest {
        val store = InMemoryStore()
        val folder = FakeFolder()
        val sync = FolderSync(store, "phone", folder)

        sync.record(block("b1", hlc(2000, "phone"), text = "newer, from phone"))
        folder.seed("tablet", listOf(block("b1", hlc(1000, "tablet"), text = "older, from tablet")))

        sync.sync()
        assertEquals("newer, from phone", textOf(store.record(Entity.BLOCK, "b1")!!))
    }

    @Test
    fun `an older local copy loses to a newer remote one`() = runTest {
        val store = InMemoryStore()
        val folder = FakeFolder()
        val sync = FolderSync(store, "phone", folder)

        sync.record(block("b1", hlc(1000, "phone"), text = "older"))
        folder.seed("tablet", listOf(block("b1", hlc(3000, "tablet"), text = "newer")))

        sync.sync()
        assertEquals("newer", textOf(store.record(Entity.BLOCK, "b1")!!))
    }

    @Test
    fun `does not re-download a file that has not changed`() = runTest {
        val folder = FakeFolder()
        folder.seed("tablet", listOf(block("b1", hlc(1000, "tablet"))))
        val sync = FolderSync(InMemoryStore(), "phone", folder)

        sync.sync()
        val afterFirst = folder.readNames.size

        val second = sync.sync().getOrThrow()
        assertEquals("re-read an unchanged file", afterFirst, folder.readNames.size)
        assertEquals(1, second.skipped)
    }

    @Test
    fun `picks the file back up once it changes again`() = runTest {
        val folder = FakeFolder()
        folder.seed("tablet", listOf(block("b1", hlc(1000, "tablet"))))
        val sync = FolderSync(InMemoryStore(), "phone", folder)
        sync.sync()

        folder.seed("tablet", listOf(block("b1", hlc(4000, "tablet"), text = "edited later")))
        assertEquals(1, sync.sync().getOrThrow().merged)
    }

    @Test
    fun `an edit made while a backup is uploading is still pending afterwards`() = runTest {
        // The local database is the source of truth and the file is a projection
        // of it, so there is no queue an in-flight edit can be deleted from. This
        // asserts the property that replaces the old outbox invariant.
        val folder = FakeFolder()
        val sync = FolderSync(InMemoryStore(), "phone", folder)

        sync.record(block("b1", hlc(1000, "phone"), text = "first"))
        sync.sync()
        assertFalse(sync.hasPendingChanges())

        sync.record(block("b1", hlc(5000, "phone"), text = "typed later"))
        assertTrue("the newer edit must still be queued for upload", sync.hasPendingChanges())

        sync.sync()
        assertFalse(sync.hasPendingChanges())
    }

    @Test
    fun `a failed upload loses nothing`() = runTest {
        val folder = FakeFolder()
        val sync = FolderSync(InMemoryStore(), "phone", folder)

        sync.record(block("b1", sync.stamp(), text = "precious"))
        folder.failure = RemoteFolderError.Offline

        assertTrue(sync.sync().isFailure)
        assertEquals(SyncState.Offline, sync.state)
        assertTrue(sync.hasPendingChanges())

        folder.failure = null
        sync.sync()
        assertFalse(sync.hasPendingChanges())
    }

    @Test
    fun `reports when no folder is connected rather than failing obscurely`() = runTest {
        val sync = FolderSync(InMemoryStore(), "phone", null)
        assertEquals(SyncState.NotConnected, sync.state)
        assertTrue(sync.sync().isFailure)
    }

    @Test
    fun `surfaces a full Drive as its own state`() = runTest {
        val folder = FakeFolder()
        val sync = FolderSync(InMemoryStore(), "phone", folder)
        sync.record(block("b1", sync.stamp()))
        folder.failure = RemoteFolderError.StorageFull

        sync.sync()
        assertEquals(SyncState.StorageFull, sync.state)
    }

    @Test
    fun `a deletion propagates as a tombstone`() = runTest {
        val store = InMemoryStore()
        val folder = FakeFolder()
        folder.seed("tablet", listOf(
            Change(Entity.BLOCK, "b1", hlc(2000, "tablet"), deleted = true),
        ))

        FolderSync(store, "phone", folder).sync()
        assertTrue(store.record(Entity.BLOCK, "b1")!!.deleted)
    }

    @Test
    fun `a record taken over by another device leaves our file`() = runTest {
        val store = InMemoryStore()
        val folder = FakeFolder()
        val sync = FolderSync(store, "phone", folder)

        sync.record(block("b1", hlc(1000, "phone"), text = "mine"))
        assertEquals(1, store.changesAuthoredBy("phone").size)

        folder.seed("tablet", listOf(block("b1", hlc(9000, "tablet"), text = "theirs")))
        sync.sync()

        assertTrue(
            "we should stop republishing a record another device now owns",
            store.changesAuthoredBy("phone").isEmpty(),
        )
    }

    @Test
    fun `the clock resumes above the newest local edit after a relaunch`() = runTest {
        val store = InMemoryStore()
        val ahead = hlc(200_000_000_000_000, "phone")
        store.recordLocal(block("b1", ahead))

        val sync = FolderSync(store, "phone", FakeFolder(), clockSource = { 1_000L })
        assertTrue(sync.stamp() > ahead)
    }

    @Test
    fun `connecting a different folder leaves nothing behind`() = runTest {
        val store = InMemoryStore()
        store.recordLocal(block("b1", hlc(1000, "phone")))
        store.setMergedVersion("device-tablet.json", "7")
        store.setLastUploadedHlc(hlc(1000, "phone"))

        store.clearAll()

        assertTrue(store.allRecords().isEmpty())
        assertTrue(store.mergedVersions().isEmpty())
        assertNull(store.lastUploadedHlc())
    }

    @Test(expected = RemoteFolderException::class)
    fun `a backup written by a newer app version is refused, not misread`() {
        val newer = DeviceFile(
            format = DeviceFile.CURRENT_FORMAT + 1,
            deviceId = "tablet", updatedAt = 0, changes = emptyList(),
        )
        DeviceFile.decode(newer.encoded())
    }

    @Test
    fun `device file names round-trip`() {
        assertEquals("device-abc123.json", DeviceFile.fileName("abc123"))
        assertEquals("abc123", DeviceFile.deviceIdFromFileName("device-abc123.json"))
        assertNull(DeviceFile.deviceIdFromFileName("license.json"))
        assertNull(DeviceFile.deviceIdFromFileName("notes.txt"))
    }

    @Test
    fun `the device file format matches the Swift implementation`() {
        // Both platforms read each other's files out of the same Drive folder, so
        // the JSON keys are a cross-platform contract, not an internal detail.
        val json = DeviceFile(deviceId = "phone", updatedAt = 5, changes = emptyList())
            .encoded().decodeToString()
        assertTrue(json.contains("\"format\":1"))
        assertTrue(json.contains("\"deviceId\":\"phone\""))
        assertTrue(json.contains("\"updatedAt\":5"))
        assertTrue(json.contains("\"changes\":[]"))
    }
}
