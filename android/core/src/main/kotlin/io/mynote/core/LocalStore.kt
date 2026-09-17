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

    /** Drop outbox entries the server accepted (or permanently rejected). */
    suspend fun removeFromOutbox(keys: List<ChangeKey>)

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

    override suspend fun removeFromOutbox(keys: List<ChangeKey>) = mutex.withLock {
        keys.forEach { pending.remove(it) }
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
