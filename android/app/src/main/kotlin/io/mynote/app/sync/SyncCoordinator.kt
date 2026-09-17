package io.mynote.app.sync

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import io.mynote.core.ApiError
import io.mynote.core.ApiException
import io.mynote.core.LocalStore
import io.mynote.core.SyncApi
import io.mynote.core.SyncEngine
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

sealed interface SyncStatus {
    data object Idle : SyncStatus
    data object Syncing : SyncStatus
    data object Offline : SyncStatus
    data class Paused(val reason: String) : SyncStatus
    data class Error(val message: String) : SyncStatus
}

/**
 * Decides *when* to sync. [SyncEngine] decides how.
 *
 * The rule this enforces: an edit is saved locally and the user moves on. Sync
 * is a background consequence, never something typing waits for.
 */
class SyncCoordinator(
    context: Context,
    store: LocalStore,
    api: SyncApi,
    deviceId: String,
    private val scope: CoroutineScope,
    private val canSync: () -> Boolean,
) {
    val engine = SyncEngine(store, api, deviceId)

    private val _status = MutableStateFlow<SyncStatus>(SyncStatus.Idle)
    val status: StateFlow<SyncStatus> = _status.asStateFlow()

    private val _lastSyncedAt = MutableStateFlow<Long?>(null)
    val lastSyncedAt: StateFlow<Long?> = _lastSyncedAt.asStateFlow()

    private val runLock = Mutex()
    private var debounceJob: Job? = null

    @Volatile
    private var online = true

    /** Long enough to batch a burst of typing, short enough to feel immediate. */
    private val debounceMs = 2_000L

    init {
        val manager = context.getSystemService(ConnectivityManager::class.java)
        manager?.registerNetworkCallback(
            NetworkRequest.Builder()
                .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .build(),
            object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    val wasOffline = !online
                    online = true
                    // Coming back online is exactly when a backlog should flush.
                    if (wasOffline) scope.launch { syncNow() }
                }

                override fun onLost(network: Network) {
                    online = false
                }
            },
        )
    }

    /** Call after any local edit. Coalesces a burst into a single round trip. */
    fun scheduleSync() {
        debounceJob?.cancel()
        debounceJob = scope.launch {
            delay(debounceMs)
            syncNow()
        }
    }

    suspend fun syncNow() {
        if (!canSync()) {
            _status.value = SyncStatus.Paused("Sync is part of MyNote Sync")
            return
        }
        if (!online) {
            _status.value = SyncStatus.Offline
            return
        }
        // A second trigger while one is in flight is a no-op, not a queued run.
        if (!runLock.tryLock()) return

        try {
            _status.value = SyncStatus.Syncing
            engine.sync()
                .onSuccess { outcome ->
                    _lastSyncedAt.value = System.currentTimeMillis()
                    _status.value = SyncStatus.Idle
                    if (outcome.rejected.isNotEmpty()) {
                        // Rejected changes are our bug, not the user's; log
                        // loudly rather than showing a scary message.
                        android.util.Log.w("MyNote", "sync rejected: ${outcome.rejected}")
                    }
                }
                .onFailure { error ->
                    _status.value = when ((error as? ApiException)?.error) {
                        ApiError.Offline -> SyncStatus.Offline
                        ApiError.SubscriptionRequired -> SyncStatus.Paused("Sync is part of MyNote Sync")
                        ApiError.Unauthenticated -> SyncStatus.Paused("Sign in to sync")
                        is ApiError.QuotaExceeded -> SyncStatus.Error((error.error as ApiError.QuotaExceeded).message)
                        is ApiError.Conflict -> SyncStatus.Error((error.error as ApiError.Conflict).message)
                        is ApiError.Server -> SyncStatus.Error((error.error as ApiError.Server).message)
                        else -> SyncStatus.Error("Sync failed. We'll retry.")
                    }
                }
        } finally {
            runLock.unlock()
        }
    }
}
