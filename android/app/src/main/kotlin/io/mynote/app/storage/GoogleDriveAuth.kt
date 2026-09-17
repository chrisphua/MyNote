package io.mynote.app.storage

import android.app.Activity
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import com.google.android.gms.auth.api.identity.AuthorizationRequest
import com.google.android.gms.auth.api.identity.AuthorizationResult
import com.google.android.gms.auth.api.identity.Identity
import com.google.android.gms.common.api.Scope
import io.mynote.core.RemoteFolderError
import io.mynote.core.RemoteFolderException
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * Obtains a Google Drive access token.
 *
 * Note what this is *not*: a sign-in. MyNote has no accounts and no identity of
 * its own, so all that is needed here is permission to write files in the user's
 * Drive. Google's authorization client handles the account picker, the consent
 * screen and token caching, which is why there is no OAuth code in this file.
 */
class GoogleDriveAuth(private val context: Context, private val serverClientId: String) {

    /**
     * Per-file access to files this app created. Deliberately *not* full `drive`
     * or `drive.readonly`: those are restricted scopes requiring a security
     * assessment, and we have no business reading anything the user did not make
     * here.
     */
    private val scope = Scope("https://www.googleapis.com/auth/drive.file")

    @Volatile
    private var cachedToken: String? = null

    val isConfigured: Boolean get() = serverClientId.isNotEmpty()

    @Volatile
    var isAuthorized: Boolean = false
        private set

    /**
     * Ask for Drive access.
     *
     * @return a [PendingIntent] the caller must launch to show Google's consent
     * screen, or null when access was already granted and a token is now held.
     */
    suspend fun authorize(): PendingIntent? {
        val request = AuthorizationRequest.builder()
            .setRequestedScopes(listOf(scope))
            // Needed for a refreshable grant rather than one that dies in an hour.
            .requestOfflineAccess(serverClientId, true)
            .build()

        val result = suspendCancellableCoroutine { continuation ->
            Identity.getAuthorizationClient(context)
                .authorize(request)
                .addOnSuccessListener { continuation.resume(it) }
                .addOnFailureListener { continuation.resumeWithException(it) }
        }

        if (result.hasResolution()) return result.pendingIntent
        adopt(result)
        return null
    }

    /** Called with the result of the consent screen. */
    fun onAuthorizationResult(activity: Activity, data: Intent?) {
        val result = runCatching {
            Identity.getAuthorizationClient(activity).getAuthorizationResultFromIntent(data)
        }.getOrNull()
        if (result != null) adopt(result)
    }

    private fun adopt(result: AuthorizationResult) {
        cachedToken = result.accessToken
        isAuthorized = result.accessToken != null
    }

    /**
     * A usable access token.
     *
     * Re-running `authorize()` is how the token is refreshed: once consent has
     * been given it returns silently, so there is no separate refresh path to
     * get wrong.
     */
    suspend fun token(): String {
        cachedToken?.let { return it }
        // Once consent has been given this returns silently, so refreshing and
        // first-time authorization are the same call and there is no separate
        // refresh path to get wrong.
        val needsConsent = authorize()
        if (needsConsent != null) {
            throw RemoteFolderException(RemoteFolderError.NeedsReauthentication)
        }
        return cachedToken
            ?: throw RemoteFolderException(RemoteFolderError.NeedsReauthentication)
    }

    fun signOut() {
        cachedToken = null
        isAuthorized = false
    }

}
