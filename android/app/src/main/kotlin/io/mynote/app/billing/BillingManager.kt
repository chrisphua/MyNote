package io.mynote.app.billing

import android.app.Activity
import android.content.Context
import com.android.billingclient.api.AcknowledgePurchaseParams
import com.android.billingclient.api.BillingClient
import com.android.billingclient.api.BillingClientStateListener
import com.android.billingclient.api.BillingFlowParams
import com.android.billingclient.api.BillingResult
import com.android.billingclient.api.PendingPurchasesParams
import com.android.billingclient.api.ProductDetails
import com.android.billingclient.api.Purchase
import com.android.billingclient.api.QueryProductDetailsParams
import com.android.billingclient.api.QueryPurchasesParams
import com.android.billingclient.api.acknowledgePurchase
import com.android.billingclient.api.queryProductDetails
import com.android.billingclient.api.queryPurchasesAsync
import io.mynote.core.Entitlement
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/**
 * Google Play Billing.
 *
 * Play is the source of truth for *making* a purchase; our Worker is the source
 * of truth for *owning* one. That split is what lets an Android purchase unlock
 * the feature on iOS: we hand Play's purchase token to the server, which records
 * the entitlement against the Firebase uid rather than the device.
 */
class BillingManager(
    context: Context,
    private val verifyWithServer: suspend (productId: String, token: String) -> List<Entitlement>,
) {
    object Products {
        const val THEMES_LIFETIME = "io.mynote.themes.lifetime"
        const val SYNC_MONTHLY = "io.mynote.sync.monthly"
        const val SYNC_YEARLY = "io.mynote.sync.yearly"

        val oneTime = listOf(THEMES_LIFETIME)
        val subscriptions = listOf(SYNC_MONTHLY, SYNC_YEARLY)

        fun entitlementFor(productId: String): String? = when (productId) {
            THEMES_LIFETIME -> "theme_pro"
            SYNC_MONTHLY, SYNC_YEARLY -> "cloud_sync"
            else -> null
        }
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private val _entitlements = MutableStateFlow<Set<String>>(emptySet())
    val entitlements: StateFlow<Set<String>> = _entitlements.asStateFlow()

    private val _products = MutableStateFlow<Map<String, ProductDetails>>(emptyMap())
    val products: StateFlow<Map<String, ProductDetails>> = _products.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error.asStateFlow()

    private val _serverConfirmed = MutableStateFlow(false)
    val serverConfirmed: StateFlow<Boolean> = _serverConfirmed.asStateFlow()

    val canCustomizeThemes: Boolean get() = "theme_pro" in _entitlements.value
    val canSync: Boolean get() = "cloud_sync" in _entitlements.value

    private val client: BillingClient = BillingClient.newBuilder(context)
        .enablePendingPurchases(PendingPurchasesParams.newBuilder().enableOneTimeProducts().build())
        .setListener { result, purchases ->
            // Fires for purchases completed here and for ones approved later,
            // such as a parent approving a child's request.
            if (result.responseCode == BillingClient.BillingResponseCode.OK && purchases != null) {
                scope.launch { purchases.forEach { handle(it) } }
            } else if (result.responseCode != BillingClient.BillingResponseCode.USER_CANCELED) {
                _error.value = describe(result)
            }
        }
        .build()

    fun connect(onReady: () -> Unit = {}) {
        client.startConnection(object : BillingClientStateListener {
            override fun onBillingSetupFinished(result: BillingResult) {
                if (result.responseCode == BillingClient.BillingResponseCode.OK) {
                    scope.launch {
                        loadProducts()
                        refreshLocalEntitlements()
                        onReady()
                    }
                } else {
                    _error.value = describe(result)
                }
            }

            override fun onBillingServiceDisconnected() {
                // Play services restarted; the next purchase attempt reconnects.
            }
        })
    }

    suspend fun loadProducts() {
        val oneTime = queryDetails(Products.oneTime, BillingClient.ProductType.INAPP)
        val subs = queryDetails(Products.subscriptions, BillingClient.ProductType.SUBS)
        _products.value = (oneTime + subs).associateBy { it.productId }
    }

    private suspend fun queryDetails(ids: List<String>, type: String): List<ProductDetails> {
        val params = QueryProductDetailsParams.newBuilder()
            .setProductList(
                ids.map {
                    QueryProductDetailsParams.Product.newBuilder()
                        .setProductId(it).setProductType(type).build()
                }
            )
            .build()
        return runCatching { client.queryProductDetails(params).productDetailsList.orEmpty() }
            .getOrElse { emptyList() }
    }

    fun launchPurchase(activity: Activity, details: ProductDetails) {
        val paramsBuilder = BillingFlowParams.ProductDetailsParams.newBuilder().setProductDetails(details)

        // A subscription must name which base plan / offer is being bought.
        details.subscriptionOfferDetails?.firstOrNull()?.let {
            paramsBuilder.setOfferToken(it.offerToken)
        }

        val flow = BillingFlowParams.newBuilder()
            .setProductDetailsParamsList(listOf(paramsBuilder.build()))
            .build()
        client.launchBillingFlow(activity, flow)
    }

    /** Re-read what this Google account owns. Required for a Restore control. */
    suspend fun refreshLocalEntitlements() {
        val found = mutableSetOf<String>()
        for (type in listOf(BillingClient.ProductType.INAPP, BillingClient.ProductType.SUBS)) {
            val params = QueryPurchasesParams.newBuilder().setProductType(type).build()
            val purchases = runCatching { client.queryPurchasesAsync(params).purchasesList }
                .getOrElse { emptyList() }
            for (purchase in purchases) {
                if (purchase.purchaseState != Purchase.PurchaseState.PURCHASED) continue
                purchase.products.mapNotNull(Products::entitlementFor).forEach(found::add)
                handle(purchase)
            }
        }
        // Union rather than replace: an entitlement bought on iOS lives only on
        // the server, and Play has never heard of it.
        _entitlements.value = _entitlements.value + found
    }

    /** Adopt the server's answer, which is authoritative across platforms. */
    fun applyServerEntitlements(list: List<Entitlement>) {
        _entitlements.value = list.filter { it.active }.map { it.entitlement }.toSet()
        _serverConfirmed.value = true
    }

    private suspend fun handle(purchase: Purchase) {
        if (purchase.purchaseState != Purchase.PurchaseState.PURCHASED) return

        val productId = purchase.products.firstOrNull() ?: return
        Products.entitlementFor(productId)?.let {
            // Unlock immediately; the server call below is confirmation, not a gate.
            _entitlements.value = _entitlements.value + it
        }

        runCatching { verifyWithServer(productId, purchase.purchaseToken) }
            .onSuccess(::applyServerEntitlements)

        // Play auto-refunds anything left unacknowledged for three days. The
        // server acknowledges too; doing it here as well costs nothing and
        // covers the case where our backend is unreachable.
        if (!purchase.isAcknowledged) {
            val params = AcknowledgePurchaseParams.newBuilder()
                .setPurchaseToken(purchase.purchaseToken).build()
            runCatching { client.acknowledgePurchase(params) }
        }
    }

    private fun describe(result: BillingResult): String = when (result.responseCode) {
        BillingClient.BillingResponseCode.BILLING_UNAVAILABLE ->
            "Google Play billing isn't available on this device."
        BillingClient.BillingResponseCode.ITEM_ALREADY_OWNED ->
            "You already own this. Try Restore purchases."
        BillingClient.BillingResponseCode.NETWORK_ERROR,
        BillingClient.BillingResponseCode.SERVICE_UNAVAILABLE ->
            "No connection to Google Play. Try again shortly."
        else -> result.debugMessage.ifBlank { "Purchase failed." }
    }
}
