package io.mynote.core

import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
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
        val existing = block("b1", "0000000000000064-0000-devA", text = "local")
        store.enqueue(existing)
        store.removeFromOutbox(listOf(existing))

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

/**
 * Runs a side effect during the *first* request only, to reproduce a user typing
 * while a push is in flight. Records every batch it was sent.
 */
private class RacingApi(private val duringFirstFlight: suspend () -> Unit) : SyncApi {
    val pushedBatches = mutableListOf<List<Change>>()
    private var calls = 0

    override suspend fun sync(cursor: Int, changes: List<Change>, limit: Int?): SyncResponse {
        pushedBatches += changes
        calls++
        if (calls == 1) duringFirstFlight()
        return SyncResponse(cursor + changes.size, emptyList(), hasMore = false, serverTime = 0)
    }
}

class SyncEngineRaceTest {

    @Test
    fun `an edit made during a push still reaches the server`() = runTest {
        val store = InMemoryStore()
        val laterHlc = "0000000000000190-0000-devA"

        // The outbox collapses edits to one row per record, so a keystroke
        // landing mid-request overwrites the very row being confirmed. Removing
        // by key alone would delete it here, unsent and unrecoverable.
        val api = RacingApi {
            store.enqueue(block("b1", laterHlc, text = "typed during push"))
        }
        val engine = SyncEngine(store, api, "devA")

        engine.enqueue(block("b1", "0000000000000064-0000-devA", text = "first"))
        engine.sync()

        val everySentHlc = api.pushedBatches.flatten().map { it.hlc }
        assertTrue(
            "the edit made during the push was never sent to the server",
            laterHlc in everySentHlc,
        )
        assertTrue(store.outbox(10).isEmpty())
    }

    @Test
    fun `the clock resumes above the newest local edit after a relaunch`() = runTest {
        val store = InMemoryStore()
        // An edit stamped far ahead of the wall clock — what a backwards system
        // clock change leaves behind.
        val ahead = "0000200000000000-0000-devA"
        store.enqueue(block("b1", ahead))

        // A fresh engine, as after a relaunch, with a wall clock well behind it.
        val engine = SyncEngine(store, FakeApi(), "devA", clockSource = { 1_000L })
        val next = engine.stamp()

        assertTrue("$next must sort above $ahead", next > ahead)
    }

    @Test
    fun `signing into a different account leaves nothing behind`() = runTest {
        val store = InMemoryStore()
        store.enqueue(block("b1", "0000000000000064-0000-devA", text = "previous account"))
        store.setCursor(99)

        store.clearAll()

        assertTrue(store.outbox(10).isEmpty())
        assertEquals(0, store.cursor())
        assertNull(store.record(Entity.BLOCK, "b1"))
    }
}
