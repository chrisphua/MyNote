package io.mynote.app.auth

import android.content.Context
import androidx.credentials.CredentialManager
import androidx.credentials.GetCredentialRequest
import androidx.credentials.exceptions.GetCredentialException
import com.google.android.libraries.identity.googleid.GetGoogleIdOption
import com.google.android.libraries.identity.googleid.GoogleIdTokenCredential
import com.google.firebase.FirebaseApp
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.auth.GoogleAuthProvider
import com.google.firebase.auth.ktx.auth
import com.google.firebase.ktx.Firebase
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.tasks.await

sealed interface AuthStatus {
    data object SignedOut : AuthStatus
    data class SignedIn(val uid: String, val email: String?) : AuthStatus
    /** No `google-services.json` in this build — local-only mode. */
    data object Unconfigured : AuthStatus
}

/**
 * Sign-in, backed by Firebase Auth.
 *
 * Firebase handles identity only — free for Google and email, and it takes
 * password resets and account recovery off our plate. Notes never touch
 * Firebase; they go to our own Worker.
 *
 * Signing in is always optional: MyNote is fully usable signed-out, and the
 * account exists so purchases and notes can follow the user to another device.
 */
class AuthManager(private val context: Context) {

    private val _status = MutableStateFlow<AuthStatus>(AuthStatus.SignedOut)
    val status: StateFlow<AuthStatus> = _status.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error.asStateFlow()

    private val configured: Boolean = FirebaseApp.getApps(context).isNotEmpty()

    init {
        if (!configured) {
            _status.value = AuthStatus.Unconfigured
        } else {
            Firebase.auth.addAuthStateListener { auth ->
                _status.value = auth.currentUser
                    ?.let { AuthStatus.SignedIn(it.uid, it.email) }
                    ?: AuthStatus.SignedOut
            }
        }
    }

    val isSignedIn: Boolean get() = status.value is AuthStatus.SignedIn

    /**
     * Fresh ID token for the Worker. Firebase refreshes it automatically near
     * expiry, so callers can ask on every request.
     */
    suspend fun idToken(): String? {
        if (!configured) return null
        val user = Firebase.auth.currentUser ?: return null
        return runCatching { user.getIdToken(false).await().token }.getOrNull()
    }

    suspend fun signIn(email: String, password: String) = guard {
        Firebase.auth.signInWithEmailAndPassword(email, password).await()
    }

    suspend fun signUp(email: String, password: String) = guard {
        Firebase.auth.createUserWithEmailAndPassword(email, password).await()
    }

    suspend fun sendPasswordReset(email: String) = guard {
        Firebase.auth.sendPasswordResetEmail(email).await()
    }

    /**
     * Google sign-in through Credential Manager, which is the supported path on
     * Android 14+ and degrades to Play Services on older releases.
     */
    suspend fun signInWithGoogle(activityContext: Context, serverClientId: String) = guard {
        val option = GetGoogleIdOption.Builder()
            .setServerClientId(serverClientId)
            .setFilterByAuthorizedAccounts(false)   // let them pick any account
            .build()
        val request = GetCredentialRequest.Builder().addCredentialOption(option).build()

        val result = CredentialManager.create(activityContext).getCredential(activityContext, request)
        val googleCredential = GoogleIdTokenCredential.createFrom(result.credential.data)
        val firebaseCredential = GoogleAuthProvider.getCredential(googleCredential.idToken, null)
        Firebase.auth.signInWithCredential(firebaseCredential).await()
    }

    fun signOut() {
        if (configured) Firebase.auth.signOut()
    }

    fun clearError() { _error.value = null }

    private suspend fun guard(block: suspend () -> Unit) {
        if (!configured) {
            _error.value = "Sign-in is not configured in this build."
            return
        }
        _error.value = null
        try {
            block()
        } catch (e: GetCredentialException) {
            _error.value = "Google sign-in was cancelled."
        } catch (e: Exception) {
            _error.value = friendly(e)
        }
    }

    /** Turn Firebase's exceptions into something a person can act on. */
    private fun friendly(e: Exception): String = when {
        e.message?.contains("password is invalid", true) == true ||
            e.message?.contains("INVALID_LOGIN_CREDENTIALS", true) == true ->
            "That email and password don't match."
        e.message?.contains("badly formatted", true) == true ->
            "That doesn't look like an email address."
        e.message?.contains("already in use", true) == true ->
            "There's already an account with that email. Try signing in."
        e.message?.contains("at least 6 characters", true) == true ->
            "Pick a password with at least 6 characters."
        e.message?.contains("network", true) == true ->
            "No connection. Your notes are saved on this device either way."
        e.message?.contains("blocked all requests", true) == true ->
            "Too many attempts. Wait a minute and try again."
        else -> e.message ?: "Something went wrong signing in."
    }
}
