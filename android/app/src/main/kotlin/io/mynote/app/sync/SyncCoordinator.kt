package io.mynote.app.sync

import android.app.PendingIntent
import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import io.mynote.app.data.RoomLocalStore
import io.mynote.app.storage.GoogleDriveAuth
import io.mynote.app.storage.GoogleDriveFolder
import io.mynote.core.FolderSync
import io.mynote.core.License
import io.mynote.core.RemoteFolder
import io.mynote.core.RemoteFolderError
import io.mynote.core.RemoteFolderException
import io.mynote.core.SyncState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex

/** Which storage the notes are backed up to. */
enum class StorageProvider(val title: String, val detail: String) {
    NONE(
        "This device only",
        "Notes stay on this phone. Nothing leaves it.",
    ),
    GOOGLE_DRIVE(
        "Google Drive",
        "Works on Android, iPhone and iPad. Files land in a MyNote folder you can open yourself.",
    );

    companion object {
        fun from(raw: String?) = entries.firstOrNull { it.name == raw } ?: NONE
    }
}

sealed interface SyncStatus {
    data object LocalOnly : SyncStatus
    data object Idle : SyncStatus
    data object Syncing : SyncStatus
    data object Offline : SyncStatus
    data object NeedsSignIn : SyncStatus
    data object StorageFull : SyncStatus
    data class Error(val message: String) : SyncStatus
}

/**
 * Decides *when* to back up. [FolderSync] decides how.
 *
 * The rule this enforces: an edit is saved locally and the user moves on.
 * Backing up is a background consequence, never something typing waits for.
 */
class SyncCoordinator(
    private val context: Context,
    private val store: RoomLocalStore,
    private val driveAuth: GoogleDriveAuth,
    deviceId: String,
    private val scope: CoroutineScope,
) {
    val engine = FolderSync(store, deviceId)

    private val _status = MutableStateFlow<SyncStatus>(SyncStatus.LocalOnly)
    val status: StateFlow<SyncStatus> = _status.asStateFlow()

    private val _provider = MutableStateFlow(StorageProvider.NONE)
    val provider: StateFlow<StorageProvider> = _provider.asStateFlow()

    private val _lastSyncedAt = MutableStateFlow<Long?>(null)
    val lastSyncedAt: StateFlow<Long?> = _lastSyncedAt.asStateFlow()

    private val _hasPendingChanges = MutableStateFlow(false)
    val hasPendingChanges: StateFlow<Boolean> = _hasPendingChanges.asStateFlow()

    /**
     * Free users may still connect a folder to restore a backup and to discover
     * a licence bought on the other platform; uploading is what Pro unlocks.
     */
    @Volatile
    var uploadsAllowed: Boolean = false

    private var folder: RemoteFolder? = null
    private val runLock = Mutex()
    private var debounceJob: Job? = null

    @Volatile
    private var online = true

    /**
     * Long enough to batch a burst of typing, short enough that picking up the
     * other device feels current. Longer than a server sync would need: a
     * whole-file upload is heavier than a delta, so it is worth coalescing more.
     */
    private val debounceMs = 5_000L

    init {
        context.getSystemService(ConnectivityManager::class.java)?.registerNetworkCallback(
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

    suspend fun restoreProvider() {
        select(StorageProvider.from(store.connectedProvider()), confirmSwitch = false)
        _lastSyncedAt.value = store.lastSyncedAt()
        refreshPending()
    }

    /**
     * Connect a storage provider.
     *
     * @return a consent intent to launch, or null when nothing more is needed.
     * @param confirmSwitch the caller's promise that the user agreed to move
     * their notes; changing folders wipes local data so two people's notes are
     * never mixed together.
     */
    suspend fun select(
        provider: StorageProvider,
        confirmSwitch: Boolean = true,
    ): PendingIntent? {
        val previous = _provider.value
        _provider.value = provider

        if (confirmSwitch && previous != StorageProvider.NONE && previous != provider) {
            store.clearAll()
        }
        store.setConnectedProvider(if (provider == StorageProvider.NONE) null else provider.name)

        return when (provider) {
            StorageProvider.NONE -> {
                folder = null
                engine.connect(null)
                _status.value = SyncStatus.LocalOnly
                null
            }

            StorageProvider.GOOGLE_DRIVE -> {
                val consent = runCatching { driveAuth.authorize() }.getOrNull()
                if (consent != null) {
                    _status.value = SyncStatus.NeedsSignIn
                    return consent
                }
                folder = GoogleDriveFolder(driveAuth)
                engine.connect(folder)
                _status.value = SyncStatus.Idle
                syncNow()
                null
            }
        }
    }

    suspend fun disconnect() {
        driveAuth.signOut()
        select(StorageProvider.NONE)
    }

    /** Call after any local edit. Coalesces a burst into one upload. */
    fun scheduleSync() {
        if (_provider.value == StorageProvider.NONE) return
        debounceJob?.cancel()
        debounceJob = scope.launch {
            delay(debounceMs)
            syncNow()
        }
    }

    suspend fun syncNow() {
        if (_provider.value == StorageProvider.NONE) {
            _status.value = SyncStatus.LocalOnly
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
            engine.sync(uploads = uploadsAllowed)
                .onSuccess {
                    _lastSyncedAt.value = System.currentTimeMillis()
                    _status.value = SyncStatus.Idle
                }
                .onFailure { error ->
                    _status.value = when ((error as? RemoteFolderException)?.error) {
                        RemoteFolderError.Offline -> SyncStatus.Offline
                        RemoteFolderError.NeedsReauthentication -> SyncStatus.NeedsSignIn
                        RemoteFolderError.StorageFull -> SyncStatus.StorageFull
                        RemoteFolderError.NotConnected -> SyncStatus.LocalOnly
                        is RemoteFolderError.NotFound -> SyncStatus.Idle
                        is RemoteFolderError.Provider ->
                            SyncStatus.Error((error.error as RemoteFolderError.Provider).message)
                        null -> SyncStatus.Error("Backup failed. We'll try again.")
                    }
                }
            refreshPending()
        } finally {
            runLock.unlock()
        }
    }

    suspend fun refreshPending() {
        _hasPendingChanges.value = engine.hasPendingChanges()
    }

    // ---- licence ------------------------------------------------------------

    /**
     * Read the licence the user's other device left in the folder.
     *
     * This is the whole cross-platform purchase mechanism: no server, just a
     * small file sitting beside the notes.
     */
    suspend fun readLicense(): License? {
        val active = folder ?: return null
        return runCatching { License.decode(active.read(License.FILE_NAME)) }.getOrNull()
    }

    suspend fun writeLicense(license: License) {
        val active = folder ?: return
        runCatching { active.write(License.FILE_NAME, license.encoded()) }
    }
}
