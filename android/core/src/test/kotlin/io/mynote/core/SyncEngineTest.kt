package io.mynote.core

import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** A scripted stand-in for the Worker. */
private class FakeApi(
    private val responses: MutableList<SyncResponse> = mutableListOf(),
    private val error: ApiError? = null,
) : SyncApi {
    val pushedBatches = mutableListOf<List<Change>>()

    override suspend fun sync(cursor: Int, changes: List<Change>, limit: Int?): SyncResponse {
        pushedBatches += changes
        error?.let { throw ApiException(it) }
        return if (responses.isEmpty()) {
            SyncResponse(cursor, emptyList(), hasMore = false, serverTime = 0)
        } else {
            responses.removeAt(0)
        }
    }
}

private fun block(id: String, hlc: String, text: String = "x", deleted: Boolean = false) = Change(
    entity = Entity.BLOCK,
    id = id,
    hlc = hlc,
    deleted = deleted,
    fields = mapOf(
        "note_id" to JsonPrimitive("n1"),
        "order_key" to JsonPrimitive("a0"),
        "type" to JsonPrimitive("paragraph"),
        "content" to JsonPrimitive(BlockContent(text = text).encoded()),
    ),
)

private fun response(
    cursor: Int,
    changes: List<Change> = emptyList(),
    hasMore: Boolean = false,
    rejected: List<Rejection> = emptyList(),
) = SyncResponse(cursor, changes, hasMore, serverTime = 0, rejected = rejected)

class SyncEngineTest {

    @Test
    fun `pushes queued edits and clears the outbox on success`() = runTest {
        val store = InMemoryStore()
        val engine = SyncEngine(store, FakeApi(mutableListOf(response(5))), "devA")

        engine.enqueue(block("b1", engine.stamp()))
        val outcome = engine.sync().getOrThrow()

        assertEquals(1, outcome.pushed)
        assertTrue(store.outbox(10).isEmpty())
        assertEquals(5, store.cursor())
    }

    @Test
    fun `keeps the edit queued when the network is down`() = runTest {
        val store = InMemoryStore()
        val engine = SyncEngine(store, FakeApi(error = ApiError.Offline), "devA")

        engine.enqueue(block("b1", engine.stamp()))
        val result = engine.sync()

        // Losing the edit here would be data loss, so it must survive.
        assertTrue(result.isFailure)
        assertEquals(1, store.outbox(10).size)
        assertEquals(SyncState.Offline, engine.state)
    }

    @Test
    fun `surfaces a missing subscription as its own state`() = runTest {
        val engine = SyncEngine(InMemoryStore(), FakeApi(error = ApiError.SubscriptionRequired), "devA")
        engine.sync()
        assertEquals(SyncState.NeedsSubscription, engine.state)
    }

    @Test
    fun `applies a remote change that is newer than the local copy`() = runTest {
        val store = InMemoryStore()
        store.enqueue(block("b1", "0000000000000064-0000-devA", text = "local"))
        store.removeFromOutbox(listOf(ChangeKey(Entity.BLOCK, "b1")))

        val remote = block("b1", "00000000000000c8-0000-devB", text = "remote")
        val engine = SyncEngine(store, FakeApi(mutableListOf(response(3, listOf(remote)))), "devA")

        engine.sync()
        val stored = store.record(Entity.BLOCK, "b1")!!
        assertEquals("remote", BlockContent.decode(stored.string("content")!!).text)
    }

    @Test
    fun `does not clobber a local edit made while the request was in flight`() = runTest {
        val store = InMemoryStore()
        store.enqueue(block("b1", "0000000000000190-0000-devA", text = "just typed"))

        val stale = block("b1", "0000000000000064-0000-devB", text = "stale server copy")
        val engine = SyncEngine(store, FakeApi(mutableListOf(response(9, listOf(stale)))), "devA")

        engine.sync()
        val stored = store.record(Entity.BLOCK, "b1")!!
        assertEquals("just typed", BlockContent.decode(stored.string("content")!!).text)
    }

    @Test
    fun `drops permanently rejected changes instead of retrying forever`() = runTest {
        val store = InMemoryStore()
        val rejection = Rejection(Entity.BLOCK, "b1", "bad_block_type")
        val engine = SyncEngine(store, FakeApi(mutableListOf(response(1, rejected = listOf(rejection)))), "devA")

        engine.enqueue(block("b1", engine.stamp()))
        val outcome = engine.sync().getOrThrow()

        assertEquals(1, outcome.rejected.size)
        assertTrue("a rejected change must not loop", store.outbox(10).isEmpty())
    }

    @Test
    fun `keeps pulling until the server has nothing left`() = runTest {
        val store = InMemoryStore()
        val api = FakeApi(mutableListOf(
            response(10, listOf(block("b1", "0000000000000064-0000-devB")), hasMore = true),
            response(20, listOf(block("b2", "0000000000000065-0000-devB")), hasMore = false),
        ))
        val engine = SyncEngine(store, api, "devA")

        val outcome = engine.sync().getOrThrow()
        assertEquals(2, outcome.pulled)
        assertEquals(20, store.cursor())
    }

    @Test
    fun `applies a tombstone`() = runTest {
        val store = InMemoryStore()
        val tombstone = Change(Entity.BLOCK, "b1", "00000000000000c8-0000-devB", deleted = true)
        val engine = SyncEngine(store, FakeApi(mutableListOf(response(4, listOf(tombstone)))), "devA")

        engine.sync()
        assertTrue(store.record(Entity.BLOCK, "b1")!!.deleted)
    }

    @Test
    fun `stamps each local edit with a strictly increasing clock`() = runTest {
        // Frozen clock: the worst case for monotonicity.
        val engine = SyncEngine(InMemoryStore(), FakeApi(), "devA", clockSource = { 1_000L })
        var previous = ""
        repeat(500) {
            val next = engine.stamp()
            assertTrue("$next not greater than $previous", next > previous)
            previous = next
        }
    }
}
