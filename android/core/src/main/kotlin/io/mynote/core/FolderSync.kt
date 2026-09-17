package io.mynote.core

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

data class SyncOutcome(
    /** Records written into our own file this pass. */
    val uploaded: Int,
    /** Records merged in from other devices. */
    val merged: Int,
    /** Device files skipped because they had not changed. */
    val skipped: Int,
)

sealed interface SyncState {
    data object Idle : SyncState
    data object Syncing : SyncState
    data object Offline : SyncState
    /** No folder connected — the app is local-only, which is a fine place to live. */
    data object NotConnected : SyncState
    data object NeedsReauthentication : SyncState
    data object StorageFull : SyncState
    data class Failed(val message: String) : SyncState
}

/**
 * Backs the notes up to the user's own Drive folder, and merges in whatever their
 * other devices have written.
 *
 * The design that makes this safe without a server: **each device writes exactly
 * one file and never touches another's.** There is no file two devices can both
 * write, so there is no write conflict to resolve and no locking. Merging happens
 * on read, by hybrid logical clock — the same last-write-wins rule as before.
 *
 * Failing is normal and cheap. The local database already holds every edit; a
 * failed sync only means the folder is briefly behind.
 */
class FolderSync(
    private val store: LocalStore,
    private val deviceId: String,
    folder: RemoteFolder? = null,
    private val clockSource: () -> Long = System::currentTimeMillis,
) {
    private val mutex = Mutex()
    private var clock = Hlc(clockSource(), 0, deviceId)
    private var didSeedClock = false

    @Volatile
    private var folder: RemoteFolder? = folder

    @Volatile
    var state: SyncState = if (folder == null) SyncState.NotConnected else SyncState.Idle
        private set

    fun connect(folder: RemoteFolder?) {
        this.folder = folder
        state = if (folder == null) SyncState.NotConnected else SyncState.Idle
    }

    val isConnected: Boolean get() = folder != null

    /** Stamp a local edit. Always use this rather than building a clock by hand. */
    suspend fun stamp(): String {
        seedClockIfNeeded()
        return mutex.withLock {
            clock = clock.tick(clockSource())
            clock.encoded()
        }
    }

    suspend fun record(change: Change) = store.recordLocal(change)

    /**
     * Bring the clock up to the newest edit this device already knows about.
     *
     * Wall time can move backwards between launches — a timezone fix, an NTP
     * correction, a manual change. Without this the next edit would stamp below
     * our own previous ones and lose to them on merge, permanently.
     */
    private suspend fun seedClockIfNeeded() {
        mutex.withLock { if (didSeedClock) return else didSeedClock = true }
        val seen = store.newestHlc()?.let(Hlc::decode) ?: return
        mutex.withLock { clock = clock.observe(seen, clockSource()) }
    }

    /** True when local records have moved on since our file was last written. */
    suspend fun hasPendingChanges(): Boolean {
        val newest = store.changesAuthoredBy(deviceId).maxOfOrNull { it.hlc } ?: return false
        val uploaded = store.lastUploadedHlc() ?: return true
        return newest > uploaded
    }

    /**
     * @param uploads when false, merge other devices' files but write nothing.
     * Lets someone restore a backup, and discover a licence bought on the other
     * platform, before they have paid.
     */
    suspend fun sync(uploads: Boolean = true): Result<SyncOutcome> {
        seedClockIfNeeded()

        val active = folder
        if (active == null) {
            state = SyncState.NotConnected
            return Result.failure(RemoteFolderException(RemoteFolderError.NotConnected))
        }

        state = SyncState.Syncing
        return try {
            val files = active.list()
            val pulled = pull(active, files)
            val uploaded = if (uploads) push(active) else 0
            state = SyncState.Idle
            Result.success(SyncOutcome(uploaded, pulled.first, pulled.second))
        } catch (e: RemoteFolderException) {
            state = stateFor(e.error)
            Result.failure(e)
        } catch (e: Exception) {
            state = SyncState.Failed("Backup failed. We'll try again.")
            Result.failure(RemoteFolderException(RemoteFolderError.Provider(e.message ?: "unknown")))
        }
    }

    /** @return merged count to skipped count */
    private suspend fun pull(folder: RemoteFolder, files: List<RemoteFile>): Pair<Int, Int> {
        val seen = store.mergedVersions()
        var merged = 0
        var skipped = 0

        for (file in files) {
            val author = DeviceFile.deviceIdFromFileName(file.name) ?: continue
            // Our own file is a projection of the local database; reading it back
            // could only ever tell us what we already know.
            if (author == deviceId) continue

            // Unchanged since the last merge: downloading it again would cost the
            // user bandwidth to learn nothing.
            if (seen[file.name] == file.version) {
                skipped++
                continue
            }

            val decoded = DeviceFile.decode(folder.read(file.name))
            for (change in decoded.changes) {
                // Same last-write-wins rule as before: only a strictly newer
                // clock may overwrite what we have.
                val local = store.currentHlc(change.entity, change.id)
                if (local != null && local >= change.hlc) continue
                store.applyRemote(change)
                merged++

                Hlc.decode(change.hlc)?.let { remote ->
                    mutex.withLock { clock = clock.observe(remote, clockSource()) }
                }
            }

            // Recorded only after every change in the file is durable, so an
            // interrupted merge replays the file rather than skipping it.
            store.setMergedVersion(file.name, file.version)
        }

        return merged to skipped
    }

    private suspend fun push(folder: RemoteFolder): Int {
        val mine = store.changesAuthoredBy(deviceId)
        val newest = mine.maxOfOrNull { it.hlc } ?: return 0

        val uploaded = store.lastUploadedHlc()
        if (uploaded != null && newest <= uploaded) return 0   // folder already current

        val file = DeviceFile(deviceId = deviceId, updatedAt = clockSource(), changes = mine)
        folder.write(DeviceFile.fileName(deviceId), file.encoded())

        // Only after the write lands. If it failed, the records stay "pending"
        // and go up next time — nothing is lost either way.
        store.setLastUploadedHlc(newest)
        return mine.size
    }

    private fun stateFor(error: RemoteFolderError): SyncState = when (error) {
        RemoteFolderError.NotConnected -> SyncState.NotConnected
        RemoteFolderError.NeedsReauthentication -> SyncState.NeedsReauthentication
        RemoteFolderError.StorageFull -> SyncState.StorageFull
        RemoteFolderError.Offline -> SyncState.Offline
        is RemoteFolderError.NotFound -> SyncState.Idle   // nothing uploaded yet
        is RemoteFolderError.Provider -> SyncState.Failed(error.message)
    }
}
