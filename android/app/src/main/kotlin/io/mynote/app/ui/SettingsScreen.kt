package io.mynote.app.ui

import android.app.Activity
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
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
import io.mynote.app.AppContainer
import io.mynote.app.auth.AuthStatus
import io.mynote.app.theme.Appearance
import io.mynote.app.theme.LocalMyNoteColors
import io.mynote.app.theme.LocalMyNoteMetrics
import io.mynote.app.theme.parseHex
import io.mynote.core.ThemeSpec
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    container: AppContainer,
    activity: Activity,
    onBack: () -> Unit,
    onOpenPaywall: () -> Unit,
    onEditTheme: (String?) -> Unit,
    onOpenSignIn: () -> Unit,
) {
    val colors = LocalMyNoteColors.current
    val metrics = LocalMyNoteMetrics.current
    val scope = rememberCoroutineScope()

    val authStatus by container.auth.status.collectAsState()
    val entitlements by container.billing.entitlements.collectAsState()
    val current by container.themeState.current.collectAsState()
    val custom by container.themeState.custom.collectAsState()
    val appearance by container.themeState.appearance.collectAsState()

    val canEdit = "theme_pro" in entitlements
    val canSync = "cloud_sync" in entitlements

    Scaffold(
        containerColor = colors.background,
        topBar = {
            TopAppBar(
                title = { Text("Settings", color = colors.textPrimary) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back", tint = colors.textSecondary)
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = colors.background),
            )
        },
    ) { padding ->
        LazyColumn(
            modifier = Modifier.padding(padding).fillMaxSize().background(colors.background),
            contentPadding = PaddingValues(metrics.contentPadding),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            item { SectionHeader("Account") }
            item {
                when (val status = authStatus) {
                    is AuthStatus.SignedIn -> Column {
                        Text(status.email ?: "Signed in", color = colors.textPrimary)
                        TextButton(onClick = { container.auth.signOut() }) { Text("Sign out") }
                    }
                    AuthStatus.SignedOut -> Column {
                        TextButton(onClick = onOpenSignIn) { Text("Sign in") }
                        Caption("Your notes are saved on this device. Sign in to sync them and to carry purchases to another device.")
                    }
                    AuthStatus.Unconfigured ->
                        Caption("This build has no sign-in credentials, so MyNote is running local-only.")
                }
            }

            item { HorizontalDivider(color = colors.border) }
            item { SectionHeader("Theme") }
            item {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    for (option in Appearance.entries) {
                        FilterChip(
                            selected = appearance == option,
                            onClick = { container.themeState.setAppearance(option) },
                            label = { Text(option.label) },
                        )
                    }
                }
            }

            items(ThemeSpec.presets + custom) { spec ->
                ThemeRow(
                    spec = spec,
                    selected = spec.id == current.id,
                    onSelect = { container.themeState.select(spec) },
                    onEdit = {
                        // The gate is here, not inside the editor, so the paywall
                        // appears before the user invests effort in a design.
                        if (canEdit) onEditTheme(if (spec.isPreset) null else spec.id)
                        else onOpenPaywall()
                    },
                )
            }

            item {
                TextButton(onClick = { if (canEdit) onEditTheme(null) else onOpenPaywall() }) {
                    if (!canEdit) {
                        Icon(Icons.Default.Lock, null, tint = colors.textSecondary)
                        Spacer(Modifier.width(6.dp))
                    }
                    Text(if (canEdit) "New theme" else "Unlock custom themes")
                }
            }
            if (!canEdit) {
                item {
                    Caption("The three built-in themes are free. Custom themes — your own colours, fonts, spacing and corners — are a one-time purchase.")
                }
            }

            item { HorizontalDivider(color = colors.border) }
            item { SectionHeader("Sync") }
            item { SyncStatusRow(container) }
            item {
                if (canSync) {
                    TextButton(onClick = { scope.launch { container.syncCoordinator.syncNow() } }) {
                        Text("Sync now")
                    }
                } else {
                    TextButton(onClick = onOpenPaywall) { Text("Turn on cloud sync") }
                }
            }

            item { HorizontalDivider(color = colors.border) }
            item { SectionHeader("Purchases") }
            item {
                Column {
                    Text("Custom themes: ${if (canEdit) "Unlocked" else "Locked"}", color = colors.textPrimary)
                    Text("Cloud sync: ${if (canSync) "Active" else "Not active"}", color = colors.textPrimary)
                    TextButton(onClick = {
                        scope.launch { container.billing.refreshLocalEntitlements() }
                    }) { Text("Restore purchases") }
                }
            }

            item { HorizontalDivider(color = colors.border) }
            item { SectionHeader("About") }
            item { Caption("MyNote ${io.mynote.app.BuildConfig.VERSION_NAME} (${io.mynote.app.BuildConfig.VERSION_CODE})") }
        }
    }
}

@Composable
private fun SectionHeader(text: String) {
    val colors = LocalMyNoteColors.current
    val metrics = LocalMyNoteMetrics.current
    Text(
        text,
        color = colors.textSecondary,
        fontSize = metrics.baseSize * 0.82f,
        fontWeight = FontWeight.Medium,
        modifier = Modifier.padding(top = 8.dp),
    )
}

@Composable
private fun Caption(text: String) {
    val colors = LocalMyNoteColors.current
    val metrics = LocalMyNoteMetrics.current
    Text(text, color = colors.textSecondary, fontSize = metrics.baseSize * 0.82f)
}

@Composable
private fun ThemeRow(
    spec: ThemeSpec,
    selected: Boolean,
    onSelect: () -> Unit,
    onEdit: () -> Unit,
) {
    val colors = LocalMyNoteColors.current
    val metrics = LocalMyNoteMetrics.current

    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(metrics.cornerRadius))
            .clickable(onClick = onSelect)
            .padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        ThemeSwatch(spec)
        Spacer(Modifier.width(10.dp))
        Text(spec.name, color = colors.textPrimary, modifier = Modifier.weight(1f))
        if (selected) {
            Icon(Icons.Default.Check, "Selected", tint = colors.accent)
            Spacer(Modifier.width(8.dp))
        }
        IconButton(onClick = onEdit) {
            Icon(Icons.Default.Edit, if (spec.isPreset) "Duplicate ${spec.name}" else "Edit ${spec.name}",
                 tint = colors.textSecondary)
        }
    }
}

/** Shows the theme's own colours, so the list is a preview rather than names. */
@Composable
fun ThemeSwatch(spec: ThemeSpec, size: Int = 24) {
    val border = parseHex(spec.light.border) ?: LocalMyNoteColors.current.border
    Box(
        Modifier
            .size(size.dp)
            .clip(CircleShape)
            .background(parseHex(spec.light.background) ?: LocalMyNoteColors.current.background),
        contentAlignment = Alignment.Center,
    ) {
        Box(
            Modifier
                .size((size * 0.4).dp)
                .clip(CircleShape)
                .background(parseHex(spec.light.accent) ?: LocalMyNoteColors.current.accent)
        )
    }
}
