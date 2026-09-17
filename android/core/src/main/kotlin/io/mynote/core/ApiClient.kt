package io.mynote.core

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.IOException
import java.util.concurrent.TimeUnit

@Serializable
data class Entitlement(
    val entitlement: String,
    val active: Boolean,
    val status: String,
    val expiresAt: Long? = null,
    val productId: String,
    val platform: String,
)

@Serializable
data class EntitlementsResponse(val entitlements: List<Entitlement>)

@Serializable
private data class ErrorBody(val error: String? = null, val code: String? = null)

@Serializable
private data class GoogleVerifyRequest(val productId: String, val purchaseToken: String)

/**
 * Talks to the Cloudflare Worker.
 *
 * The Firebase ID token is fetched per request via [tokenProvider] so a refreshed
 * token is picked up without rebuilding the client.
 */
class ApiClient(
    private val baseUrl: String,
    private val tokenProvider: suspend () -> String?,
    private val client: OkHttpClient = defaultClient(),
) : SyncApi {

    override suspend fun sync(cursor: Int, changes: List<Change>, limit: Int?): SyncResponse =
        post("/v1/sync", MyNoteJson.encodeToString(SyncRequest.serializer(), SyncRequest(cursor, changes, limit)))
            .let { MyNoteJson.decodeFromString(SyncResponse.serializer(), it) }

    suspend fun entitlements(): List<Entitlement> =
        MyNoteJson.decodeFromString(EntitlementsResponse.serializer(), get("/v1/entitlements")).entitlements

    suspend fun verifyGooglePurchase(productId: String, purchaseToken: String): List<Entitlement> {
        val body = MyNoteJson.encodeToString(
            GoogleVerifyRequest.serializer(),
            GoogleVerifyRequest(productId, purchaseToken),
        )
        return MyNoteJson
            .decodeFromString(EntitlementsResponse.serializer(), post("/v1/iap/google/verify", body))
            .entitlements
    }

    // ---- transport ---------------------------------------------------------

    private suspend fun get(path: String): String = execute(requestBuilder(path).get())

    private suspend fun post(path: String, json: String): String =
        execute(requestBuilder(path).post(json.toRequestBody(JSON_MEDIA)))

    private suspend fun requestBuilderToken(): String {
        return tokenProvider() ?: throw ApiException(ApiError.Unauthenticated)
    }

    private fun requestBuilder(path: String): Request.Builder =
        Request.Builder().url(baseUrl.trimEnd('/') + path)

    private suspend fun execute(builder: Request.Builder): String = withContext(Dispatchers.IO) {
        val request = builder
            .header("Authorization", "Bearer ${requestBuilderToken()}")
            .header("Content-Type", "application/json")
            .build()

        val response = try {
            client.newCall(request).execute()
        } catch (e: IOException) {
            throw ApiException(ApiError.Offline)
        }

        response.use {
            val body = it.body?.string().orEmpty()
            if (!it.isSuccessful) throw ApiException(mapError(it.code, body))
            body
        }
    }

    private fun mapError(status: Int, body: String): ApiError {
        val parsed = runCatching { MyNoteJson.decodeFromString(ErrorBody.serializer(), body) }.getOrNull()
        val message = parsed?.error ?: "request failed"
        return when (status) {
            401 -> ApiError.Unauthenticated
            402 -> ApiError.SubscriptionRequired
            507 -> ApiError.QuotaExceeded(message)
            409 -> ApiError.Conflict(message)
            else -> ApiError.Server(status, parsed?.code ?: "error", message)
        }
    }

    companion object {
        private val JSON_MEDIA = "application/json; charset=utf-8".toMediaType()

        /** Sync must never block the UI, so a stalled network just means "later". */
        fun defaultClient(): OkHttpClient = OkHttpClient.Builder()
            .connectTimeout(15, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .writeTimeout(30, TimeUnit.SECONDS)
            .retryOnConnectionFailure(true)
            .build()
    }
}
