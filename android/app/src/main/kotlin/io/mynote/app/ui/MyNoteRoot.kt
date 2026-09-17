package io.mynote.app.ui

import android.app.Activity
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.width
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.VerticalDivider
import androidx.compose.material3.windowsizeclass.WindowSizeClass
import androidx.compose.material3.windowsizeclass.WindowWidthSizeClass
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import io.mynote.app.AppContainer
import io.mynote.app.theme.LocalMyNoteColors
import kotlinx.coroutines.launch

/**
 * Top-level layout.
 *
 * On a compact width (most phones, portrait) this is a stack: list, then editor.
 * On medium and expanded widths (tablets, foldables, landscape phones) both
 * panes are visible at once. That single branch is the whole responsive story —
 * every screen below sizes itself from the theme, not from hard-coded widths.
 */
@Composable
fun MyNoteRoot(
    container: AppContainer,
    windowSizeClass: WindowSizeClass,
    activity: Activity,
) {
    val colors = LocalMyNoteColors.current
    val scope = rememberCoroutineScope()

    var selectedNoteId by remember { mutableStateOf<String?>(null) }
    var screen by remember { mutableStateOf<Screen>(Screen.Notes) }

    val entitlements by container.billing.entitlements.collectAsState()

    LaunchedEffect(entitlements) {
        container.applyEntitlements()
    }

    val twoPane = windowSizeClass.widthSizeClass != WindowWidthSizeClass.Compact

    Box(Modifier.fillMaxSize().background(colors.background)) {
        when (val current = screen) {
            Screen.Notes -> {
                if (twoPane) {
                    Row(Modifier.fillMaxSize()) {
                        Box(Modifier.width(320.dp).fillMaxHeight()) {
                            NoteListScreen(
                                container = container,
                                selectedNoteId = selectedNoteId,
                                onSelect = { selectedNoteId = it },
                                onOpenSettings = { screen = Screen.Settings },
                            )
                        }
                        VerticalDivider(color = colors.border)
                        Box(Modifier.weight(1f).fillMaxHeight()) {
                            val id = selectedNoteId
                            if (id == null) {
                                EmptyDetail()
                            } else {
                                NoteEditorScreen(
                                    container = container,
                                    noteId = id,
                                    showBackButton = false,
                                    onBack = { selectedNoteId = null },
                                )
                            }
                        }
                    }
                } else {
                    val id = selectedNoteId
                    if (id == null) {
                        NoteListScreen(
                            container = container,
                            selectedNoteId = null,
                            onSelect = { selectedNoteId = it },
                            onOpenSettings = { screen = Screen.Settings },
                        )
                    } else {
                        NoteEditorScreen(
                            container = container,
                            noteId = id,
                            showBackButton = true,
                            onBack = { selectedNoteId = null },
                        )
                    }
                }
            }

            Screen.Settings -> SettingsScreen(
                container = container,
                activity = activity,
                onBack = { screen = Screen.Notes },
                onOpenPaywall = { screen = Screen.Paywall },
                onEditTheme = { screen = Screen.ThemeEditor(it) },
            )

            Screen.Paywall -> PaywallScreen(
                container = container,
                activity = activity,
                onClose = { screen = Screen.Settings },
            )

            is Screen.ThemeEditor -> ThemeEditorScreen(
                container = container,
                initial = current.themeId,
                onClose = { screen = Screen.Settings },
                onSave = { spec ->
                    scope.launch { container.repository.saveTheme(spec) }
                    screen = Screen.Settings
                },
            )
        }
    }
}

sealed interface Screen {
    data object Notes : Screen
    data object Settings : Screen
    data object Paywall : Screen
    data class ThemeEditor(val themeId: String?) : Screen
}

@Composable
private fun EmptyDetail() {
    val colors = LocalMyNoteColors.current
    Box(Modifier.fillMaxSize().background(colors.background), contentAlignment = Alignment.Center) {
        Text("Pick a note, or start a new one.", color = colors.textSecondary)
    }
}
