package io.mynote.app

import android.content.Context
import androidx.core.content.edit
import io.mynote.app.auth.AuthManager
import io.mynote.app.auth.AuthStatus
import io.mynote.app.billing.BillingManager
import io.mynote.app.data.MyNoteDatabase
import io.mynote.app.data.RoomLocalStore
import io.mynote.app.sync.NoteRepository
import io.mynote.app.sync.SyncCoordinator
import io.mynote.app.theme.ThemeState
import io.mynote.core.ApiClient
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import java.util.UUID

/**
 * Hand-rolled dependency container.
 *
 * A DI framework would earn its keep in a larger app; here it would add build
 * time and indirection for six objects that are all created once at launch.
 */
class AppContainer(context: Context) {
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    val database = MyNoteDatabase.get(context)
    val store = RoomLocalStore(database)
    val auth = AuthManager(context)
    val themeState = ThemeState(context)

    val api = ApiClient(
        baseUrl = BuildConfig.API_BASE_URL,
        tokenProvider = { auth.idToken() },
    )

    val billing = BillingManager(context) { productId, token ->
        api.verifyGooglePurchase(productId, token)
    }

    val syncCoordinator = SyncCoordinator(
        context = context,
        store = store,
        api = api,
        deviceId = deviceId(context),
        scope = scope,
        canSync = { billing.canSync },
    )

    val repository = NoteRepository(database, syncCoordinator)

    /**
     * Adopt the server's view of what this account owns.
     *
     * The server is the only place that knows about a purchase made on iOS, so
     * without this call "buy on iOS, unlocked on Android" never happens.
     */
    suspend fun refreshEntitlements() {
        if (!auth.isSignedIn) return
        runCatching { api.entitlements() }
            .onSuccess(billing::applyServerEntitlements)
        // Offline, or no purchases yet — Play's local view still applies, so a
        // purchase made on this device keeps working either way.
        themeState.canEdit = billing.canCustomizeThemes
    }

    /**
     * Wipe local data when the signed-in account changes.
     *
     * Local rows carry no uid. Without this, signing out of A and into B would
     * push A's queued notes into B's account, and B would inherit A's cursor and
     * never pull its own records.
     */
    suspend fun reconcileAccount(context: Context) {
        val prefs = context.getSharedPreferences("mynote.sync", Context.MODE_PRIVATE)
        val previous = prefs.getString(OWNER_KEY, null)
        val current = (auth.status.value as? AuthStatus.SignedIn)?.uid

        // Signing out alone leaves the data with its owner, so it is still there
        // when they sign back in. Only a *different* account wipes.
        if (current == null || current == previous) {
            if (current != null) prefs.edit { putString(OWNER_KEY, current) }
            return
        }

        if (previous != null) {
            store.clearAll()
            themeState.forgetSyncedThemes()
        }
        prefs.edit { putString(OWNER_KEY, current) }
    }

    /** Themes sync as ordinary records; this is where they join the picker. */
    suspend fun loadSyncedThemes() {
        themeState.mergeSynced(store.syncedThemes())
    }

    private companion object {
        const val OWNER_KEY = "ownerUid"
    }

    /**
     * Stable per-install id, used as the HLC node so two devices never produce
     * the same clock. Not derived from a hardware identifier: those need
     * permissions and can be shared between a phone and its clone.
     */
    private fun deviceId(context: Context): String {
        val prefs = context.getSharedPreferences("mynote.sync", Context.MODE_PRIVATE)
        return prefs.getString("deviceId", null) ?: UUID.randomUUID().toString().take(8).also {
            prefs.edit { putString("deviceId", it) }
        }
    }
}
