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
import io.mynote.app.AppFeatures
import io.mynote.core.License
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
 * One product. With no server to run, MyNote has no recurring cost, so charging
 * a recurring price would be asking for money to cover an expense that does not
 * exist. A single lifetime unlock is the honest shape.
 */
class BillingManager(
    context: Context,
    /** Called after a purchase so the licence can be written to the user's folder. */
    private val onPurchase: suspend (License) -> Unit,
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private val _entitlements = MutableStateFlow<Set<String>>(emptySet())
    val entitlements: StateFlow<Set<String>> = _entitlements.asStateFlow()

    private val _product = MutableStateFlow<ProductDetails?>(null)
    val product: StateFlow<ProductDetails?> = _product.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error.asStateFlow()

    /** True once a licence from the cloud folder has been merged in. */
    private val _sawRemoteLicense = MutableStateFlow(false)
    val sawRemoteLicense: StateFlow<Boolean> = _sawRemoteLicense.asStateFlow()

    /** While nothing is for sale, everyone has everything. */
    val isPro: Boolean
        get() = !AppFeatures.PAID_FEATURES_ENABLED || PRO_ENTITLEMENT in _entitlements.value

    private val client: BillingClient = BillingClient.newBuilder(context)
        .enablePendingPurchases(PendingPurchasesParams.newBuilder().enableOneTimeProducts().build())
        .setListener { result, purchases ->
            // Fires for purchases completed here and for ones approved later,
            // such as a parent approving a child's request.
            if (result.responseCode == BillingClient.BillingResponseCode.OK && purchases != null) {
                scope.launch { purchases.forEach { adopt(it) } }
            } else if (result.responseCode != BillingClient.BillingResponseCode.USER_CANCELED) {
                _error.value = describe(result)
            }
        }
        .build()

    fun connect() {
        // Nothing is for sale, so there is nothing to connect to. Skipping this
        // also keeps the app off Play Billing at launch entirely.
        if (!AppFeatures.PAID_FEATURES_ENABLED) return

        client.startConnection(object : BillingClientStateListener {
            override fun onBillingSetupFinished(result: BillingResult) {
                if (result.responseCode == BillingClient.BillingResponseCode.OK) {
                    scope.launch {
                        loadProduct()
                        refreshLocalEntitlements()
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

    suspend fun loadProduct() {
        if (!AppFeatures.PAID_FEATURES_ENABLED) return
        val params = QueryProductDetailsParams.newBuilder()
            .setProductList(
                listOf(
                    QueryProductDetailsParams.Product.newBuilder()
                        .setProductId(PRO_PRODUCT_ID)
                        .setProductType(BillingClient.ProductType.INAPP)
                        .build()
                )
            )
            .build()
        _product.value = runCatching {
            client.queryProductDetails(params).productDetailsList?.firstOrNull()
        }.getOrNull()
    }

    fun launchPurchase(activity: Activity) {
        val details = _product.value ?: return
        val flow = BillingFlowParams.newBuilder()
            .setProductDetailsParamsList(
                listOf(
                    BillingFlowParams.ProductDetailsParams.newBuilder()
                        .setProductDetails(details)
                        .build()
                )
            )
            .build()
        client.launchBillingFlow(activity, flow)
    }

    /** Re-read what this Google account owns. Required for a Restore control. */
    suspend fun refreshLocalEntitlements() {
        if (!AppFeatures.PAID_FEATURES_ENABLED) return
        val params = QueryPurchasesParams.newBuilder()
            .setProductType(BillingClient.ProductType.INAPP)
            .build()
        val purchases = runCatching { client.queryPurchasesAsync(params).purchasesList }
            .getOrElse { emptyList() }
        purchases.forEach { adopt(it, announce = false) }
    }

    /**
     * Adopt a licence found in the user's cloud folder.
     *
     * Union with what Play says, never a replacement: a purchase made on iOS
     * exists only in the file, and one made here may not be uploaded yet.
     * Neither may revoke the other.
     */
    fun applyRemoteLicense(license: License?) {
        if (!AppFeatures.PAID_FEATURES_ENABLED || license == null) return
        _entitlements.value = License.combine(_entitlements.value, license)
        _sawRemoteLicense.value = true
    }

    private suspend fun adopt(purchase: Purchase, announce: Boolean = true) {
        if (purchase.purchaseState != Purchase.PurchaseState.PURCHASED) return
        if (PRO_PRODUCT_ID !in purchase.products) return

        _entitlements.value = _entitlements.value + PRO_ENTITLEMENT

        // Play auto-refunds anything left unacknowledged for three days.
        if (!purchase.isAcknowledged) {
            runCatching {
                client.acknowledgePurchase(
                    AcknowledgePurchaseParams.newBuilder()
                        .setPurchaseToken(purchase.purchaseToken)
                        .build()
                )
            }
        }

        if (announce) {
            onPurchase(
                License(
                    entitlements = listOf(PRO_ENTITLEMENT),
                    productId = PRO_PRODUCT_ID,
                    platform = "google",
                    purchasedAt = purchase.purchaseTime,
                    receipt = purchase.purchaseToken,
                )
            )
        }
    }

    private fun describe(result: BillingResult): String = when (result.responseCode) {
        BillingClient.BillingResponseCode.BILLING_UNAVAILABLE ->
            "Google Play billing isn't available on this device."
        BillingClient.BillingResponseCode.ITEM_ALREADY_OWNED ->
            "You already own this. Try Restore purchase."
        BillingClient.BillingResponseCode.NETWORK_ERROR,
        BillingClient.BillingResponseCode.SERVICE_UNAVAILABLE ->
            "No connection to Google Play. Try again shortly."
        else -> result.debugMessage.ifBlank { "Purchase failed." }
    }

    companion object {
        const val PRO_PRODUCT_ID = "com.chrisphua.mynote.pro"
        const val PRO_ENTITLEMENT = "pro"
    }
}
