package io.mynote.app

import android.content.Context
import androidx.core.content.edit
import io.mynote.app.auth.AuthManager
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
