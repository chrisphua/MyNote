package io.mynote.core

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * What the sync engine needs from local persistence. The app backs this with
 * Room; tests use [InMemoryStore].
 */
interface LocalStore {
    /** Highest `serverSeq` this device has durably applied. */
    suspend fun cursor(): Int
    suspend fun setCursor(value: Int)

    /** Local edits not yet acknowledged by the server, oldest first. */
    suspend fun outbox(limit: Int): List<Change>
    suspend fun enqueue(change: Change)

    /**
     * Drop outbox entries the server has resolved — accepted or permanently
     * rejected — identified by the exact version that was sent.
     *
     * Removal is by `(key, hlc)`, never by key alone. The store collapses a
     * burst of typing onto one outbox row, so a keystroke landing *while a push
     * is in flight* overwrites that row with a newer clock. Deleting by key
     * would drop the newer edit without ever having sent it: silent, permanent
     * note loss.
     */
    suspend fun removeFromOutbox(sent: List<Change>)

    /**
     * Newest clock this device has seen, across records and the outbox.
     *
     * Used to seed the clock at launch so it cannot restart behind its own
     * previous edits after the system clock moves backwards.
     */
    suspend fun newestHlc(): String?

    /**
     * Wipe every local record, the outbox and the cursor.
     *
     * Called when the signed-in account changes: local rows carry no `uid`, so
     * without this the previous account's queued edits would be pushed into the
     * new one.
     */
    suspend fun clearAll()

    /** The clock on our copy of a record, or null if we have never seen it. */
    suspend fun currentHlc(entity: Entity, id: String): String?

    /** Overwrite the local copy with the server's version. */
    suspend fun applyRemote(change: Change)
}

/** Reference implementation used by tests. */
class InMemoryStore : LocalStore {
    private val mutex = Mutex()
    private val records = mutableMapOf<ChangeKey, Change>()
    private val pending = LinkedHashMap<ChangeKey, Change>()
    private var cursorValue = 0

    override suspend fun cursor(): Int = mutex.withLock { cursorValue }

    override suspend fun setCursor(value: Int) = mutex.withLock { cursorValue = value }

    override suspend fun outbox(limit: Int): List<Change> =
        mutex.withLock { pending.values.take(limit) }

    override suspend fun enqueue(change: Change) = mutex.withLock {
        records[change.key] = change
        pending[change.key] = change
    }

    override suspend fun removeFromOutbox(sent: List<Change>) = mutex.withLock {
        for (change in sent) {
            // Only if this is still the version we pushed.
            if (pending[change.key]?.hlc == change.hlc) pending.remove(change.key)
        }
    }

    override suspend fun newestHlc(): String? = mutex.withLock {
        (records.values.map { it.hlc } + pending.values.map { it.hlc }).maxOrNull()
    }

    override suspend fun clearAll() = mutex.withLock {
        records.clear()
        pending.clear()
        cursorValue = 0
    }

    override suspend fun currentHlc(entity: Entity, id: String): String? =
        mutex.withLock { records[ChangeKey(entity, id)]?.hlc }

    override suspend fun applyRemote(change: Change) = mutex.withLock {
        records[change.key] = change
        Unit
    }

    suspend fun record(entity: Entity, id: String): Change? =
        mutex.withLock { records[ChangeKey(entity, id)] }
}
