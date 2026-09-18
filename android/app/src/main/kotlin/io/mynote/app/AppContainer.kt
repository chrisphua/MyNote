package io.mynote.app

import android.content.Context
import androidx.core.content.edit
import io.mynote.app.billing.BillingManager
import io.mynote.app.data.MyNoteDatabase
import io.mynote.app.data.RoomLocalStore
import io.mynote.app.storage.GoogleDriveAuth
import io.mynote.app.sync.NoteRepository
import io.mynote.app.sync.SyncCoordinator
import io.mynote.app.theme.ThemeState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import java.util.UUID

/**
 * Hand-rolled dependency container.
 *
 * A DI framework would earn its keep in a larger app; here it would add build
 * time and indirection for six objects that are all created once at launch.
 */
class AppContainer(private val context: Context) {
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    val database = MyNoteDatabase.get(context)
    val store = RoomLocalStore(database)
    val themeState = ThemeState(context)

    val driveAuth = GoogleDriveAuth(context, BuildConfig.GOOGLE_OAUTH_CLIENT_ID)

    val syncCoordinator = SyncCoordinator(
        context = context,
        store = store,
        driveAuth = driveAuth,
        deviceId = deviceId(context),
        scope = scope,
    )

    // A purchase on this device is written into the folder so the user's other
    // platform picks it up. There is no server to tell.
    val billing = BillingManager(context) { license ->
        syncCoordinator.writeLicense(license)
    }

    val repository = NoteRepository(database, syncCoordinator)

    /** Run once at launch. */
    fun start() {
        billing.connect()
        scope.launch {
            syncCoordinator.restoreProvider()
            // Read the licence *before* deciding whether uploads are allowed:
            // this is how a purchase made on iOS unlocks an Android device.
            billing.applyRemoteLicense(syncCoordinator.readLicense())
            applyEntitlements()
            loadSyncedThemes()
            seedWelcomeNoteIfNeeded(context)
            syncCoordinator.refreshPending()
        }
    }

    /**
     * Greet a fresh install, once.
     *
     * Guarded on the database being empty as well as on the flag: someone
     * reinstalling with notes already in their Drive should not find a sample
     * note sitting on top of their own writing. Runs after the folder has been
     * read, so a restored backup wins.
     */
    private suspend fun seedWelcomeNoteIfNeeded(context: Context) {
        val prefs = context.getSharedPreferences("mynote.sync", Context.MODE_PRIVATE)
        if (prefs.getBoolean(WELCOME_SEEDED, false)) return
        if (database.notes().count() > 0) return

        // The flag is set after the note exists, not before. Setting it first
        // meant a throw or a process death in between left the flag claiming a
        // note that was never written.
        repository.seedWelcomeNote()
        prefs.edit { putBoolean(WELCOME_SEEDED, true) }
    }

    /** Keep the theme gate and the upload gate in step with what the user owns. */
    fun applyEntitlements() {
        themeState.canEdit = billing.isPro
        syncCoordinator.uploadsAllowed = billing.isPro
    }

    suspend fun loadSyncedThemes() {
        themeState.mergeSynced(store.syncedThemes())
    }

    /** Delete every note on this device. */
    suspend fun eraseLocalData() {
        store.clearAll()
        themeState.forgetSyncedThemes()
    }

    /**
     * Stable per-install id, used as the HLC node and as this device's file name.
     * Not derived from a hardware identifier: those need permissions and can be
     * shared between a phone and its clone.
     */
    private fun deviceId(context: Context): String {
        val prefs = context.getSharedPreferences("mynote.sync", Context.MODE_PRIVATE)
        return prefs.getString("deviceId", null)
            ?: UUID.randomUUID().toString().take(8).also {
                prefs.edit { putString("deviceId", it) }
            }
    }

    private companion object {
        const val WELCOME_SEEDED = "welcomeSeeded"
    }
}
