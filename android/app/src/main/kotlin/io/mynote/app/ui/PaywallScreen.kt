package io.mynote.app.ui

import android.app.Activity
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import io.mynote.app.AppContainer
import io.mynote.app.theme.LocalMyNoteColors
import io.mynote.app.theme.LocalMyNoteMetrics
import kotlinx.coroutines.launch

/**
 * The paywall.
 *
 * One product, one price, paid once. There is no server behind MyNote, so there
 * is no recurring cost to cover and no honest case for a recurring charge.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PaywallScreen(container: AppContainer, activity: Activity, onClose: () -> Unit) {
    val colors = LocalMyNoteColors.current
    val metrics = LocalMyNoteMetrics.current
    val scope = rememberCoroutineScope()

    val product by container.billing.product.collectAsState()
    val entitlements by container.billing.entitlements.collectAsState()
    val error by container.billing.error.collectAsState()
    val isPro = "pro" in entitlements

    Scaffold(
        containerColor = colors.background,
        topBar = {
            TopAppBar(
                title = { Text("MyNote Pro", color = colors.textPrimary) },
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
                        "Unlimited notes, every block type and three themes cost nothing, forever. Pro adds the two things people ask for most.",
                        color = colors.textSecondary,
                        fontSize = metrics.baseSize,
                    )
                }
            }

            item {
                Column(
                    Modifier
                        .widthIn(max = 560.dp)
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(metrics.cornerRadius))
                        .background(colors.surface)
                        .border(2.dp, colors.accent, RoundedCornerShape(metrics.cornerRadius))
                        .padding(16.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    Row(verticalAlignment = Alignment.Top) {
                        Column(Modifier.weight(1f)) {
                            Text("MyNote Pro", color = colors.textPrimary,
                                 fontSize = metrics.baseSize * 1.15f,
                                 fontWeight = metrics.headingWeight)
                            Text("One payment. Yours for good.", color = colors.textSecondary,
                                 fontSize = metrics.baseSize * 0.82f)
                        }
                        Text(
                            product?.oneTimePurchaseOfferDetails?.formattedPrice ?: "—",
                            color = colors.textPrimary,
                            fontSize = metrics.baseSize * 1.15f,
                            fontWeight = FontWeight.Medium,
                        )
                    }

                    for (bullet in listOf(
                        "Design your own themes — colours for light and dark, fonts, spacing, corners",
                        "Back up to your own Google Drive",
                        "Keep every device in step, automatically",
                        "Your notes stay in storage you control. We host nothing.",
                    )) {
                        Row(verticalAlignment = Alignment.Top) {
                            Icon(Icons.Default.Check, null, tint = colors.accent)
                            Spacer(Modifier.width(8.dp))
                            Text(bullet, color = colors.textSecondary, fontSize = metrics.baseSize)
                        }
                    }

                    Button(
                        onClick = { container.billing.launchPurchase(activity) },
                        enabled = product != null && !isPro,
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Text(if (isPro) "Already yours" else "Unlock Pro")
                    }
                }
            }

            item {
                Text(
                    "Buy on either platform. If you back up to Google Drive, connecting the same account on an iPhone unlocks Pro there too — the receipt travels with your notes.",
                    color = colors.textSecondary,
                    fontSize = metrics.baseSize * 0.82f,
                    modifier = Modifier
                        .clip(RoundedCornerShape(metrics.cornerRadius))
                        .background(colors.surface)
                        .padding(12.dp),
                )
            }

            error?.let {
                item { Text(it, color = Color.Red, fontSize = metrics.baseSize * 0.82f) }
            }

            item {
                TextButton(onClick = {
                    scope.launch { container.billing.refreshLocalEntitlements() }
                }) { Text("Restore purchase") }
            }
        }
    }
}
