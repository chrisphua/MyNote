package io.mynote.app.ui

import android.app.Activity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.IntentSenderRequest
import androidx.activity.result.contract.ActivityResultContracts
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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material3.AlertDialog
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
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import io.mynote.app.AppContainer
import io.mynote.app.AppFeatures
import io.mynote.app.sync.StorageProvider
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
) {
    val colors = LocalMyNoteColors.current
    val metrics = LocalMyNoteMetrics.current
    val scope = rememberCoroutineScope()

    val entitlements by container.billing.entitlements.collectAsState()
    val provider by container.syncCoordinator.provider.collectAsState()
    val current by container.themeState.current.collectAsState()
    val custom by container.themeState.custom.collectAsState()
    val appearance by container.themeState.appearance.collectAsState()
    val sawRemote by container.billing.sawRemoteLicense.collectAsState()

    val isPro = "pro" in entitlements
    var pendingSwitch by remember { mutableStateOf<StorageProvider?>(null) }
    var confirmErase by remember { mutableStateOf(false) }

    // Google's consent screen comes back through here.
    val consentLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.StartIntentSenderForResult()
    ) { result ->
        container.driveAuth.onAuthorizationResult(activity, result.data)
        scope.launch {
            container.syncCoordinator.select(StorageProvider.GOOGLE_DRIVE, confirmSwitch = false)
            container.billing.applyRemoteLicense(container.syncCoordinator.readLicense())
            container.applyEntitlements()
            container.loadSyncedThemes()
        }
    }

    suspend fun connect(target: StorageProvider) {
        val consent = container.syncCoordinator.select(target)
        if (consent != null) {
            consentLauncher.launch(IntentSenderRequest.Builder(consent).build())
            return
        }
        container.billing.applyRemoteLicense(container.syncCoordinator.readLicense())
        container.applyEntitlements()
        container.loadSyncedThemes()
    }

    fun choose(target: StorageProvider) {
        if (target == provider) return
        if (provider != StorageProvider.NONE) {
            pendingSwitch = target       // switching wipes; confirm first
        } else {
            scope.launch { connect(target) }
        }
    }

    pendingSwitch?.let { target ->
        AlertDialog(
            onDismissRequest = { pendingSwitch = null },
            title = { Text("Move your notes?") },
            // Records carry no account, so mixing two backups would put one
            // person's notes into another's Drive. Saying this plainly beats
            // silently deleting.
            text = {
                Text(
                    "Notes on this device will be removed and replaced with whatever is in " +
                        "${target.title}. Anything not already backed up will be lost."
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    pendingSwitch = null
                    scope.launch { connect(target) }
                }) { Text("Switch") }
            },
            dismissButton = {
                TextButton(onClick = { pendingSwitch = null }) { Text("Cancel") }
            },
        )
    }

    if (confirmErase) {
        AlertDialog(
            onDismissRequest = { confirmErase = false },
            title = { Text("Erase every note on this phone?") },
            text = {
                Text(
                    if (provider == StorageProvider.NONE) {
                        "These notes are not backed up anywhere. This cannot be undone."
                    } else {
                        "Your backup in ${provider.title} is untouched."
                    }
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    confirmErase = false
                    scope.launch { container.eraseLocalData() }
                }) { Text("Erase", color = Color.Red) }
            },
            dismissButton = {
                TextButton(onClick = { confirmErase = false }) { Text("Cancel") }
            },
        )
    }

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
            if (container.backupAvailable) {
                item { SectionHeader("Backup") }
                items(StorageProvider.entries) { option ->
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(metrics.cornerRadius))
                            .clickable { choose(option) }
                            .padding(vertical = 10.dp),
                        verticalAlignment = Alignment.Top,
                    ) {
                        Column(Modifier.weight(1f)) {
                            Text(option.title, color = colors.textPrimary)
                            Text(option.detail, color = colors.textSecondary,
                                 fontSize = metrics.baseSize * 0.82f)
                        }
                        if (provider == option) {
                            Icon(Icons.Default.Check, "Selected", tint = colors.accent)
                        }
                    }
                }
                item { SyncStatusRow(container) }
                item {
                    Caption("MyNote has no servers. Your notes go to storage you already own, and we never see them.")
                }
                if (provider != StorageProvider.NONE) {
                    item {
                        TextButton(onClick = { scope.launch { container.syncCoordinator.syncNow() } }) {
                            Text("Back up now")
                        }
                    }
                }

                item { HorizontalDivider(color = colors.border) }
            }
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
                        if (isPro) onEditTheme(if (spec.isPreset) null else spec.id)
                        else onOpenPaywall()
                    },
                )
            }
            item {
                TextButton(onClick = { if (isPro) onEditTheme(null) else onOpenPaywall() }) {
                    if (!isPro) {
                        Icon(Icons.Default.Lock, null, tint = colors.textSecondary)
                        Spacer(Modifier.width(6.dp))
                    }
                    Text(if (isPro) "New theme" else "Unlock custom themes")
                }
            }
            if (!isPro) {
                item { Caption("The three built-in themes are free. Building your own is part of Pro.") }
            }

            if (AppFeatures.PAID_FEATURES_ENABLED) {
                item { HorizontalDivider(color = colors.border) }
                item { SectionHeader("MyNote Pro") }
                item {
                    Column {
                        Text("Status: ${if (isPro) "Unlocked" else "Not purchased"}",
                             color = colors.textPrimary)
                        if (!isPro) {
                            TextButton(onClick = onOpenPaywall) { Text("See what's included") }
                        }
                        TextButton(onClick = {
                            scope.launch { container.billing.refreshLocalEntitlements() }
                        }) { Text("Restore purchase") }
                        if (sawRemote) {
                            Caption("Unlocked from a purchase found in your backup.")
                        }
                    }
                }
            }

            item { HorizontalDivider(color = colors.border) }
            item { SectionHeader("About") }
            item {
                Caption("MyNote ${io.mynote.app.BuildConfig.VERSION_NAME} (${io.mynote.app.BuildConfig.VERSION_CODE})")
            }
            item {
                TextButton(onClick = { confirmErase = true }) {
                    Text("Erase notes on this device", color = Color.Red)
                }
            }
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
            Icon(
                Icons.Default.Edit,
                if (spec.isPreset) "Duplicate ${spec.name}" else "Edit ${spec.name}",
                tint = colors.textSecondary,
            )
        }
    }
}

/** Shows the theme's own colours, so the list is a preview rather than names. */
@Composable
fun ThemeSwatch(spec: ThemeSpec, size: Int = 24) {
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
