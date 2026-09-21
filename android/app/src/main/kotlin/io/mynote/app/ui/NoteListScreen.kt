package io.mynote.app.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Icon
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import io.mynote.app.AppContainer
import io.mynote.app.data.NoteRow
import io.mynote.app.sync.SyncStatus
import io.mynote.app.theme.LocalMyNoteColors
import io.mynote.app.theme.LocalMyNoteMetrics
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun NoteListScreen(
    container: AppContainer,
    selectedNoteId: String?,
    onSelect: (String) -> Unit,
    onOpenSettings: () -> Unit,
) {
    val colors = LocalMyNoteColors.current
    val metrics = LocalMyNoteMetrics.current
    val scope = rememberCoroutineScope()

    val notes by container.database.notes().observeAll()
        .collectAsState(initial = emptyList())
    var query by remember { mutableStateOf("") }

    val visible = remember(notes, query) {
        if (query.isBlank()) notes
        else notes.filter { it.title.contains(query, ignoreCase = true) }
    }

    Scaffold(
        containerColor = colors.background,
        topBar = {
            TopAppBar(
                title = { Text("MyNote", color = colors.textPrimary) },
                navigationIcon = {
                    IconButton(onClick = onOpenSettings) {
                        Icon(Icons.Default.Settings, "Settings", tint = colors.textSecondary)
                    }
                },
                actions = {
                    IconButton(onClick = {
                        scope.launch { onSelect(container.repository.createNote()) }
                    }) {
                        Icon(Icons.Default.Add, "New note", tint = colors.accent)
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = colors.background),
            )
        },
    ) { padding ->
        Column(Modifier.padding(padding).fillMaxSize().background(colors.background)) {
            SearchField(query, { query = it })
            SyncStatusRow(container)

            if (visible.isEmpty()) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Text(
                        if (query.isBlank()) "No notes yet." else "Nothing matches “$query”.",
                        color = colors.textSecondary,
                    )
                }
            } else {
                LazyColumn(
                    contentPadding = androidx.compose.foundation.layout.PaddingValues(
                        horizontal = metrics.contentPadding,
                        vertical = 4.dp,
                    ),
                    verticalArrangement = Arrangement.spacedBy(2.dp),
                ) {
                    items(visible, key = { it.id }) { note ->
                        NoteListRow(
                            note = note,
                            selected = note.id == selectedNoteId,
                            onClick = { onSelect(note.id) },
                            onDelete = { scope.launch { container.repository.deleteNote(note.id) } },
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun SearchField(value: String, onChange: (String) -> Unit) {
    val colors = LocalMyNoteColors.current
    val metrics = LocalMyNoteMetrics.current

    Row(
        Modifier
            .padding(horizontal = metrics.contentPadding, vertical = 8.dp)
            .fillMaxWidth()
            .clip(RoundedCornerShape(metrics.cornerRadius))
            .background(colors.surface)
            .padding(horizontal = 12.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Default.Search, null, tint = colors.textSecondary)
        Spacer(Modifier.width(8.dp))
        Box(Modifier.weight(1f)) {
            if (value.isEmpty()) {
                Text("Search notes", color = colors.textSecondary, fontSize = metrics.baseSize)
            }
            BasicTextField(
                value = value,
                onValueChange = onChange,
                singleLine = true,
                textStyle = TextStyle(color = colors.textPrimary, fontSize = metrics.baseSize),
                cursorBrush = SolidColor(colors.accent),
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}

/**
 * A note in the list, with swipe-to-delete.
 *
 * There used to be a bin on every row. It made deleting the most prominent
 * thing you could do to a note you had just written, and it is not an action
 * anyone needs one tap away. iOS has always deleted by swiping; this now
 * matches, so the affordance is discoverable without being an invitation.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun NoteListRow(
    note: NoteRow,
    selected: Boolean,
    onClick: () -> Unit,
    onDelete: () -> Unit,
) {
    val colors = LocalMyNoteColors.current
    val metrics = LocalMyNoteMetrics.current

    val dismiss = rememberSwipeToDismissBoxState(
        confirmValueChange = { value ->
            if (value == SwipeToDismissBoxValue.EndToStart) {
                onDelete()
                true
            } else {
                false
            }
        },
        // A deliberate swipe, not a brush past it.
        positionalThreshold = { distance -> distance * 0.5f },
    )

    SwipeToDismissBox(
        state = dismiss,
        enableDismissFromStartToEnd = false,
        backgroundContent = {
            Box(
                Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(metrics.cornerRadius))
                    // A literal rather than a theme colour: the theme model is
                    // shared with iOS and synced, and a swipe background is not
                    // worth a wire-format change. This is the red iOS uses for
                    // the same gesture.
                    .background(Color(0xFFE5484D))
                    .padding(horizontal = 20.dp),
                contentAlignment = Alignment.CenterEnd,
            ) {
                Icon(Icons.Default.Delete, "Delete note", tint = colors.background)
            }
        },
    ) {
        NoteListRowContent(note, selected, onClick)
    }
}

@Composable
private fun NoteListRowContent(
    note: NoteRow,
    selected: Boolean,
    onClick: () -> Unit,
) {
    val colors = LocalMyNoteColors.current
    val metrics = LocalMyNoteMetrics.current

    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(metrics.cornerRadius))
            .background(if (selected) colors.surface else colors.background)
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(
                note.title.ifBlank { "Untitled" },
                color = colors.textPrimary,
                fontSize = metrics.baseSize,
                fontWeight = if (selected) FontWeight.Medium else FontWeight.Normal,
                maxLines = 1,
            )
            Text(
                relativeTime(note.updatedAt),
                color = colors.textSecondary,
                fontSize = metrics.baseSize * 0.78f,
            )
        }
    }
}

/** Small, always-visible truth about whether edits have left the device. */
@Composable
fun SyncStatusRow(container: AppContainer) {
    val colors = LocalMyNoteColors.current
    val metrics = LocalMyNoteMetrics.current

    val status by container.syncCoordinator.status.collectAsState()
    val pending by container.syncCoordinator.hasPendingChanges.collectAsState()
    val lastSynced by container.syncCoordinator.lastSyncedAt.collectAsState()
    val provider by container.syncCoordinator.provider.collectAsState()

    val message = when (val current = status) {
        SyncStatus.LocalOnly -> "Saved on this device"
        SyncStatus.Syncing -> "Backing up\u2026"
        SyncStatus.Offline -> if (pending) "Offline \u2014 changes waiting" else "Offline"
        SyncStatus.NeedsSignIn -> "Reconnect ${provider.title}"
        SyncStatus.StorageFull -> "${provider.title} is full"
        is SyncStatus.Error -> current.message
        SyncStatus.Idle -> when {
            pending -> "Changes waiting"
            lastSynced != null -> "Backed up ${relativeTime(lastSynced!!)}"
            else -> "Saved on this device"
        }
    }

    Text(
        message,
        color = colors.textSecondary,
        fontSize = metrics.baseSize * 0.78f,
        modifier = Modifier.padding(horizontal = metrics.contentPadding + 12.dp, vertical = 2.dp),
    )
}

fun relativeTime(epochMillis: Long): String {
    val delta = System.currentTimeMillis() - epochMillis
    return when {
        delta < 60_000 -> "just now"
        delta < 3_600_000 -> "${delta / 60_000}m ago"
        delta < 86_400_000 -> "${delta / 3_600_000}h ago"
        else -> "${delta / 86_400_000}d ago"
    }
}
