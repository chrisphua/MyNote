package io.mynote.core

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * What the sync engine needs from local persistence.
 *
 * The local database is the source of truth. The file in the user's cloud folder
 * is a *projection* of it, rewritten whenever local records change — so a failed
 * upload can never lose an edit, it only delays one. That is a stronger property
 * than the outbox this replaced, and it is why there is no queue here any more.
 */
interface LocalStore {
    /**
     * Every record whose newest known version was authored by [node].
     *
     * A record's HLC carries the device that wrote it, so this is just a filter
     * on the clock — no separate authorship column. When another device takes
     * over a record, it drops out of ours automatically.
     */
    suspend fun changesAuthoredBy(node: String): List<Change>

    /** Record a local edit. Returns immediately; upload happens later. */
    suspend fun recordLocal(change: Change)

    /** The clock on our copy of a record, or null if we have never seen it. */
    suspend fun currentHlc(entity: Entity, id: String): String?

    /** Overwrite the local copy with a version merged from another device. */
    suspend fun applyRemote(change: Change)

    /** Provider version of each remote file we have already merged. */
    suspend fun mergedVersions(): Map<String, String>
    suspend fun setMergedVersion(file: String, version: String)

    /**
     * Newest clock we had when our own file was last uploaded. Anything newer
     * than this means the folder is behind the device.
     */
    suspend fun lastUploadedHlc(): String?
    suspend fun setLastUploadedHlc(hlc: String)

    /**
     * Newest clock this device has seen, across every record. Seeds the clock at
     * launch so it cannot restart behind its own previous edits after the system
     * clock moves backwards.
     */
    suspend fun newestHlc(): String?

    /**
     * Wipe every local record and all sync bookkeeping.
     *
     * Called when the connected folder changes: records carry no account, so
     * without this one person's notes would be uploaded into another's Drive.
     */
    suspend fun clearAll()
}

/** The device that authored this version, read out of its clock. */
val Change.authorNode: String?
    get() = Hlc.decode(hlc)?.node

/** Reference implementation used by tests. */
class InMemoryStore : LocalStore {
    private val mutex = Mutex()
    private val records = mutableMapOf<ChangeKey, Change>()
    private val versions = mutableMapOf<String, String>()
    private var uploaded: String? = null

    override suspend fun changesAuthoredBy(node: String): List<Change> = mutex.withLock {
        records.values.filter { it.authorNode == node }
    }

    override suspend fun recordLocal(change: Change) = mutex.withLock {
        records[change.key] = change
        Unit
    }

    override suspend fun currentHlc(entity: Entity, id: String): String? = mutex.withLock {
        records[ChangeKey(entity, id)]?.hlc
    }

    override suspend fun applyRemote(change: Change) = mutex.withLock {
        records[change.key] = change
        Unit
    }

    override suspend fun mergedVersions(): Map<String, String> = mutex.withLock { versions.toMap() }

    override suspend fun setMergedVersion(file: String, version: String) = mutex.withLock {
        versions[file] = version
        Unit
    }

    override suspend fun lastUploadedHlc(): String? = mutex.withLock { uploaded }

    override suspend fun setLastUploadedHlc(hlc: String) = mutex.withLock { uploaded = hlc }

    override suspend fun newestHlc(): String? = mutex.withLock {
        records.values.maxOfOrNull { it.hlc }
    }

    override suspend fun clearAll() = mutex.withLock {
        records.clear()
        versions.clear()
        uploaded = null
    }

    suspend fun record(entity: Entity, id: String): Change? =
        mutex.withLock { records[ChangeKey(entity, id)] }

    suspend fun allRecords(): List<Change> = mutex.withLock { records.values.toList() }
}
