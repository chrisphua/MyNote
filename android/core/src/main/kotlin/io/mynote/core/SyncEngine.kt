package io.mynote.core

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

sealed interface ApiError {
    data object Unauthenticated : ApiError
    /** No active `cloud_sync` entitlement — show the paywall. */
    data object SubscriptionRequired : ApiError
    data object Offline : ApiError
    data class QuotaExceeded(val message: String) : ApiError
    data class Conflict(val message: String) : ApiError
    data class Server(val status: Int, val code: String, val message: String) : ApiError
    data class Decoding(val message: String) : ApiError
}

class ApiException(val error: ApiError) : Exception(error.toString())

/** The slice of the API the engine needs; a fake stands in for it in tests. */
interface SyncApi {
    suspend fun sync(cursor: Int, changes: List<Change>, limit: Int? = null): SyncResponse
}

data class SyncOutcome(
    val pushed: Int,
    val pulled: Int,
    val rejected: List<Rejection>,
    val cursor: Int,
)

sealed interface SyncState {
    data object Idle : SyncState
    data object Syncing : SyncState
    data object Offline : SyncState
    data object NeedsSubscription : SyncState
    data class Failed(val message: String) : SyncState
}

/**
 * Drives one sync pass: push what we changed, pull what changed elsewhere.
 *
 * Deliberately dumb about *when* it runs. Editing always writes locally first and
 * returns immediately; this runs afterwards, and failing is normal (the device is
 * on a plane). Nothing here may lose a local edit: an entry leaves the outbox only
 * once the server has confirmed it.
 */
class SyncEngine(
    private val store: LocalStore,
    private val api: SyncApi,
    deviceId: String,
    private val batchSize: Int = 400,
    private val clockSource: () -> Long = System::currentTimeMillis,
) {
    private val mutex = Mutex()
    private var clock = Hlc(clockSource(), 0, deviceId)
    private var didSeedClock = false

    @Volatile
    var state: SyncState = SyncState.Idle
        private set

    /**
     * Stamp a local edit. Always use this rather than building an hlc by hand, so
     * the device's clock stays monotonic even if the system clock jumps back.
     */
    suspend fun stamp(): String {
        seedClockIfNeeded()
        return mutex.withLock {
            clock = clock.tick(clockSource())
            clock.encoded()
        }
    }

    /**
     * Bring the clock up to the newest edit this device already knows about.
     *
     * The in-memory clock starts from wall time, and wall time can move
     * backwards between launches — a timezone fix, an NTP correction, a manual
     * change. Without this, the next edit would stamp *below* the server's copy,
     * the server's `excluded.hlc > hlc` guard would silently no-op it, and the
     * local copy would diverge permanently.
     */
    private suspend fun seedClockIfNeeded() {
        mutex.withLock { if (didSeedClock) return else didSeedClock = true }
        val seen = store.newestHlc()?.let(Hlc::decode) ?: return
        mutex.withLock { clock = clock.observe(seen, clockSource()) }
    }

    suspend fun enqueue(change: Change) = store.enqueue(change)

    suspend fun sync(): Result<SyncOutcome> {
        seedClockIfNeeded()
        state = SyncState.Syncing
        var pushed = 0
        var pulled = 0
        val rejected = mutableListOf<Rejection>()
        var cursor = store.cursor()

        // Loop until the server has nothing left, so a device catching up after a
        // long time offline finishes in one call.
        while (true) {
            val pendingBatch = store.outbox(batchSize)

            val response = try {
                api.sync(cursor, pendingBatch)
            } catch (e: ApiException) {
                state = stateFor(e.error)
                return Result.failure(e)
            } catch (e: Exception) {
                state = SyncState.Offline
                return Result.failure(ApiException(ApiError.Offline))
            }

            apply(response)

            // Everything we sent is now resolved: accepted, or rejected as
            // permanently invalid (retrying those would loop forever). Hand the
            // batch back so the store can drop each row only if it still holds
            // the version we pushed.
            val rejectedKeys = response.rejected.map { ChangeKey(it.entity, it.id) }.toSet()
            store.removeFromOutbox(pendingBatch)

            pushed += pendingBatch.size - rejectedKeys.size
            pulled += response.changes.size
            rejected += response.rejected
            cursor = response.cursor

            if (!response.hasMore && store.outbox(1).isEmpty()) break
        }

        state = SyncState.Idle
        return Result.success(SyncOutcome(pushed, pulled, rejected, cursor))
    }

    private suspend fun apply(response: SyncResponse) {
        for (change in response.changes) {
            // The server already resolved conflicts, but a local edit made *while
            // this request was in flight* can still be newer. Re-checking here is
            // what stops sync from clobbering a fresh keystroke.
            val local = store.currentHlc(change.entity, change.id)
            if (local != null && local >= change.hlc) continue
            store.applyRemote(change)

            Hlc.decode(change.hlc)?.let { remote ->
                mutex.withLock { clock = clock.observe(remote, clockSource()) }
            }
        }
        // Persist the cursor only after the whole page is durable, so a crash
        // mid-apply replays the page instead of skipping it.
        store.setCursor(response.cursor)
    }

    private fun stateFor(error: ApiError): SyncState = when (error) {
        ApiError.Offline -> SyncState.Offline
        ApiError.SubscriptionRequired -> SyncState.NeedsSubscription
        ApiError.Unauthenticated -> SyncState.Failed("signed out")
        is ApiError.QuotaExceeded -> SyncState.Failed(error.message)
        is ApiError.Conflict -> SyncState.Failed(error.message)
        is ApiError.Server -> SyncState.Failed(error.message)
        is ApiError.Decoding -> SyncState.Failed(error.message)
    }
}
