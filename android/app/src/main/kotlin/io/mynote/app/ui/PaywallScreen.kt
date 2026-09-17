package io.mynote.app.ui

import android.app.Activity
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.android.billingclient.api.ProductDetails
import io.mynote.app.AppContainer
import io.mynote.app.billing.BillingManager
import io.mynote.app.theme.LocalMyNoteColors
import io.mynote.app.theme.LocalMyNoteMetrics
import kotlinx.coroutines.launch

/**
 * The paywall.
 *
 * Two separate things are on sale, and the copy says so plainly: a one-time
 * unlock for themes, and a subscription for sync. Bundling them would force
 * people who only want their own colours into a recurring charge.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PaywallScreen(container: AppContainer, activity: Activity, onClose: () -> Unit) {
    val colors = LocalMyNoteColors.current
    val metrics = LocalMyNoteMetrics.current
    val scope = rememberCoroutineScope()

    val products by container.billing.products.collectAsState()
    val entitlements by container.billing.entitlements.collectAsState()
    val error by container.billing.error.collectAsState()

    Scaffold(
        containerColor = colors.background,
        topBar = {
            TopAppBar(
                title = { Text("Upgrade", color = colors.textPrimary) },
                navigationIcon = {
                    IconButton(onClick = onClose) {
                        Icon(Icons.Default.Close, "Not now", tint = colors.textSecondary)
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = colors.background),
            )
        },
    ) { padding ->
        LazyColumn(
            modifier = Modifier.padding(padding).fillMaxSize().background(colors.background),
            contentPadding = PaddingValues(metrics.contentPadding),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            item {
                Column(Modifier.widthIn(max = 560.dp)) {
                    Text(
                        "MyNote is free to write in.",
                        color = colors.textPrimary,
                        fontSize = metrics.baseSize * 1.4f,
                        fontWeight = metrics.headingWeight,
                    )
                    Spacer(Modifier.padding(4.dp))
                    Text(
                        "Unlimited notes, every block type and three themes cost nothing, forever. These two add-ons are what keep it that way.",
                        color = colors.textSecondary,
                        fontSize = metrics.baseSize,
                    )
                }
            }

            item {
                PurchaseCard(
                    details = products[BillingManager.Products.THEMES_LIFETIME],
                    title = "Custom themes",
                    subtitle = "One payment, yours for good",
                    owned = "theme_pro" in entitlements,
                    bullets = listOf(
                        "Design your own colour palettes for light and dark",
                        "Choose fonts, text size and line height",
                        "Tune spacing, corners and page width",
                        "Unlimited saved themes",
                    ),
                    onBuy = { container.billing.launchPurchase(activity, it) },
                )
            }

            item {
                PurchaseCard(
                    details = products[BillingManager.Products.SYNC_YEARLY],
                    title = "Cloud sync — yearly",
                    subtitle = "Best value",
                    owned = "cloud_sync" in entitlements,
                    highlighted = true,
                    bullets = listOf(
                        "Your notes on every device you sign in to",
                        "Android, iPhone and iPad share one account",
                        "1 GB for images and attachments",
                        "Keeps working offline; syncs when you're back",
                    ),
                    onBuy = { container.billing.launchPurchase(activity, it) },
                )
            }

            item {
                PurchaseCard(
                    details = products[BillingManager.Products.SYNC_MONTHLY],
                    title = "Cloud sync — monthly",
                    subtitle = "Cancel any time",
                    owned = "cloud_sync" in entitlements,
                    bullets = emptyList(),
                    onBuy = { container.billing.launchPurchase(activity, it) },
                )
            }

            item {
                Text(
                    "Buy once, on either platform. Sign in with the same account on iPhone and it's already unlocked.",
                    color = colors.textSecondary,
                    fontSize = metrics.baseSize * 0.82f,
                    modifier = Modifier
                        .clip(RoundedCornerShape(metrics.cornerRadius))
                        .background(colors.surface)
                        .padding(12.dp),
                )
            }

            error?.let {
                item { Text(it, color = androidx.compose.ui.graphics.Color.Red, fontSize = metrics.baseSize * 0.82f) }
            }

            item {
                TextButton(onClick = { scope.launch { container.billing.refreshLocalEntitlements() } }) {
                    Text("Restore purchases")
                }
            }

            item {
                // Play requires subscription terms to be visible at the point of sale.
                Text(
                    "Subscriptions renew automatically until cancelled. Manage or cancel in Google Play › Subscriptions at least 24 hours before the period ends.",
                    color = colors.textSecondary,
                    fontSize = metrics.baseSize * 0.78f,
                )
            }
        }
    }
}

@Composable
private fun PurchaseCard(
    details: ProductDetails?,
    title: String,
    subtitle: String,
    owned: Boolean,
    bullets: List<String>,
    highlighted: Boolean = false,
    onBuy: (ProductDetails) -> Unit,
) {
    val colors = LocalMyNoteColors.current
    val metrics = LocalMyNoteMetrics.current

    Column(
        Modifier
            .widthIn(max = 560.dp)
            .fillMaxWidth()
            .clip(RoundedCornerShape(metrics.cornerRadius))
            .background(colors.surface)
            .border(
                if (highlighted) 2.dp else 1.dp,
                if (highlighted) colors.accent else colors.border,
                RoundedCornerShape(metrics.cornerRadius),
            )
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(verticalAlignment = Alignment.Top) {
            Column(Modifier.weight(1f)) {
                Text(title, color = colors.textPrimary,
                     fontSize = metrics.baseSize * 1.15f, fontWeight = metrics.headingWeight)
                Text(subtitle, color = colors.textSecondary, fontSize = metrics.baseSize * 0.82f)
            }
            Text(
                priceOf(details) ?: "—",
                color = colors.textPrimary,
                fontSize = metrics.baseSize * 1.15f,
                fontWeight = FontWeight.Medium,
            )
        }

        for (bullet in bullets) {
            Row(verticalAlignment = Alignment.Top) {
                Icon(Icons.Default.Check, null, tint = colors.accent)
                Spacer(Modifier.width(8.dp))
                Text(bullet, color = colors.textSecondary, fontSize = metrics.baseSize)
            }
        }

        Button(
            onClick = { details?.let(onBuy) },
            enabled = details != null && !owned,
            modifier = Modifier.fillMaxWidth(),
        ) {
            Text(if (owned) "Already yours" else "Continue")
        }
    }
}

/**
 * Play reports one-time and subscription prices in different places, so both
 * are checked rather than assuming the product type.
 */
private fun priceOf(details: ProductDetails?): String? {
    if (details == null) return null
    details.oneTimePurchaseOfferDetails?.formattedPrice?.let { return it }
    return details.subscriptionOfferDetails
        ?.firstOrNull()
        ?.pricingPhases
        ?.pricingPhaseList
        ?.lastOrNull()
        ?.formattedPrice
}
