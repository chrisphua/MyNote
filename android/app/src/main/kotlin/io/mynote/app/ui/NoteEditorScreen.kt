package io.mynote.app.ui

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
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.CheckBox
import androidx.compose.material.icons.filled.CheckBoxOutlineBlank
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import io.mynote.app.AppContainer
import io.mynote.app.data.BlockRow
import io.mynote.app.theme.LocalMyNoteColors
import io.mynote.app.theme.LocalMyNoteMetrics
import io.mynote.core.Block
import io.mynote.core.BlockContent
import io.mynote.core.BlockType
import io.mynote.core.EditorEcho
import kotlinx.coroutines.launch

/**
 * The block editor.
 *
 * The content column is centred and capped at the theme's `maxContentWidth`, so
 * the same screen is comfortable on a small phone and does not stretch to
 * unreadable line lengths on a tablet.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun NoteEditorScreen(
    container: AppContainer,
    noteId: String,
    showBackButton: Boolean,
    onBack: () -> Unit,
) {
    val colors = LocalMyNoteColors.current
    val metrics = LocalMyNoteMetrics.current
    val scope = rememberCoroutineScope()

    val note by container.database.notes().observeById(noteId)
        .collectAsState(initial = null)
    val blocks by container.database.blocks().observeForNote(noteId)
        .collectAsState(initial = emptyList())

    Scaffold(
        containerColor = colors.background,
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        note?.title?.ifBlank { "Untitled" } ?: "Untitled",
                        color = colors.textPrimary,
                        maxLines = 1,
                    )
                },
                navigationIcon = {
                    if (showBackButton) {
                        IconButton(onClick = onBack) {
                            Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back", tint = colors.textSecondary)
                        }
                    }
                },
                actions = {
                    IconButton(onClick = {
                        scope.launch {
                            container.repository.appendBlock(noteId, blocks.lastOrNull()?.orderKey)
                        }
                    }) {
                        Icon(Icons.Default.Add, "Add block", tint = colors.accent)
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = colors.background),
            )
        },
    ) { padding ->
        Box(Modifier.padding(padding).fillMaxSize().background(colors.background)) {
            LazyColumn(
                modifier = Modifier
                    .widthIn(max = metrics.maxContentWidth)
                    .fillMaxWidth()
                    .align(Alignment.TopCenter),
                contentPadding = PaddingValues(metrics.contentPadding),
                verticalArrangement = Arrangement.spacedBy(metrics.blockSpacing),
            ) {
                item {
                    TitleField(
                        title = note?.title.orEmpty(),
                        onChange = { newTitle ->
                            val current = note ?: return@TitleField
                            scope.launch {
                                container.repository.rename(
                                    noteId = current.id,
                                    title = newTitle,
                                    icon = current.icon,
                                    parentId = current.parentId,
                                    orderKey = current.orderKey,
                                )
                            }
                        },
                    )
                }

                items(blocks, key = { it.id }) { row ->
                    BlockEditor(
                        row = row,
                        onChange = { updated -> scope.launch { container.repository.update(updated) } },
                        onSplit = {
                            scope.launch {
                                val next = blocks.firstOrNull { it.orderKey > row.orderKey }?.orderKey
                                container.repository.appendBlock(noteId, row.orderKey, next)
                            }
                        },
                        onDelete = {
                            // Never leave a note with zero blocks — there would
                            // be nowhere to type.
                            if (blocks.size > 1) {
                                scope.launch { container.repository.deleteBlock(row.id) }
                            }
                        },
                    )
                }

                item {
                    // Tapping the space below the last block starts a new one,
                    // the way a paper page lets you keep writing.
                    Box(
                        Modifier
                            .fillMaxWidth()
                            .height(120.dp)
                            .clickable {
                                scope.launch {
                                    container.repository.appendBlock(noteId, blocks.lastOrNull()?.orderKey)
                                }
                            }
                    )
                }
            }
        }
    }
}

@Composable
private fun TitleField(title: String, onChange: (String) -> Unit) {
    val colors = LocalMyNoteColors.current
    val metrics = LocalMyNoteMetrics.current
    var local by remember(title) { mutableStateOf(title) }

    Box(Modifier.fillMaxWidth().padding(bottom = 8.dp)) {
        if (local.isEmpty()) {
            Text("Untitled", color = colors.textSecondary, fontSize = metrics.baseSize * 1.75f)
        }
        BasicTextField(
            value = local,
            onValueChange = { local = it; onChange(it) },
            textStyle = TextStyle(
                color = colors.textPrimary,
                fontSize = metrics.baseSize * 1.75f,
                fontWeight = metrics.headingWeight,
            ),
            cursorBrush = SolidColor(colors.accent),
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

@Composable
private fun BlockEditor(
    row: BlockRow,
    onChange: (Block) -> Unit,
    onSplit: () -> Unit,
    onDelete: () -> Unit,
) {
    val colors = LocalMyNoteColors.current
    val metrics = LocalMyNoteMetrics.current

    val type = BlockType.fromWire(row.type) ?: BlockType.PARAGRAPH
    val content = remember(row.content) { BlockContent.decode(row.content) }
    var text by remember(row.id) { mutableStateOf(content.text) }
    var menuOpen by remember { mutableStateOf(false) }
    var isFocused by remember(row.id) { mutableStateOf(false) }

    // Distinguishes the store echoing our own keystrokes from a genuine edit
    // arriving from another device. Without it this screen had the opposite
    // problem to iOS: it never adopted a remote edit at all, so a change made
    // elsewhere stayed invisible until the note was reopened. See EditorEcho.
    val echo = remember(row.id) { EditorEcho() }

    LaunchedEffect(row.content) {
        val incoming = BlockContent.decode(row.content).text
        // Never fight the person typing, and never adopt our own write coming
        // back — it can arrive out of order and would clobber the field.
        if (!isFocused && echo.shouldAdopt(incoming) && incoming != text) {
            text = incoming
        }
    }

    fun emit(newText: String = text, newContent: BlockContent = content, newType: BlockType = type) {
        // Recorded before the write goes out, so the echo is recognised whenever
        // it comes back.
        echo.sending(newText)
        onChange(
            Block(
                id = row.id,
                noteId = row.noteId,
                parentId = row.parentId,
                orderKey = row.orderKey,
                type = newType,
                content = newContent.copy(text = newText),
                hlc = row.hlc,
            )
        )
    }

    if (type == BlockType.DIVIDER) {
        HorizontalDivider(Modifier.padding(vertical = 8.dp), color = colors.border)
        return
    }

    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(if (type == BlockType.CODE) metrics.cornerRadius else 0.dp))
            .background(if (type == BlockType.CODE) colors.codeBackground else colors.background)
            .padding(if (type == BlockType.CODE) 10.dp else 0.dp),
        verticalAlignment = Alignment.Top,
    ) {
        when (type) {
            BlockType.TODO_ITEM -> {
                val checked = content.checked ?: false
                IconButton(onClick = { emit(newContent = content.copy(checked = !checked)) }) {
                    Icon(
                        if (checked) Icons.Default.CheckBox else Icons.Default.CheckBoxOutlineBlank,
                        if (checked) "Completed" else "Not completed",
                        tint = colors.accent,
                    )
                }
            }
            BlockType.BULLET -> {
                Text("•", color = colors.textSecondary, fontSize = metrics.baseSize)
                Spacer(Modifier.width(8.dp))
            }
            BlockType.NUMBERED -> {
                Text("1.", color = colors.textSecondary, fontSize = metrics.baseSize)
                Spacer(Modifier.width(8.dp))
            }
            BlockType.QUOTE -> {
                Box(Modifier.width(3.dp).height(metrics.baseSize.value.dp * 1.4f).background(colors.accent))
                Spacer(Modifier.width(10.dp))
            }
            else -> Unit
        }

        Box(Modifier.weight(1f)) {
            if (text.isEmpty()) {
                Text(
                    placeholderFor(type),
                    color = colors.textSecondary,
                    fontSize = fontSizeFor(type, metrics.baseSize),
                )
            }
            BasicTextField(
                value = text,
                onValueChange = { text = it; emit(newText = it) },
                textStyle = TextStyle(
                    color = if (type == BlockType.QUOTE) colors.textSecondary else colors.textPrimary,
                    fontSize = fontSizeFor(type, metrics.baseSize),
                    fontFamily = if (type == BlockType.CODE) FontFamily.Monospace else FontFamily.Default,
                    fontWeight = if (type.isHeading) metrics.headingWeight else null,
                    lineHeight = metrics.lineHeight,
                ),
                cursorBrush = SolidColor(colors.accent),
                modifier = Modifier
                    .fillMaxWidth()
                    .onFocusChanged { isFocused = it.isFocused },
            )
        }

        Box {
            IconButton(onClick = { menuOpen = true }) {
                Text("⋮", color = colors.textSecondary)
            }
            DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                for (candidate in BlockType.entries) {
                    DropdownMenuItem(
                        text = { Text(candidate.label) },
                        onClick = {
                            menuOpen = false
                            emit(newType = candidate)
                        },
                    )
                }
                HorizontalDivider()
                DropdownMenuItem(
                    text = { Text("Delete block") },
                    onClick = { menuOpen = false; onDelete() },
                )
            }
        }
    }
}

private val BlockType.isHeading: Boolean
    get() = this == BlockType.HEADING1 || this == BlockType.HEADING2 || this == BlockType.HEADING3

val BlockType.label: String
    get() = when (this) {
        BlockType.PARAGRAPH -> "Text"
        BlockType.HEADING1 -> "Heading 1"
        BlockType.HEADING2 -> "Heading 2"
        BlockType.HEADING3 -> "Heading 3"
        BlockType.TODO_ITEM -> "To-do"
        BlockType.BULLET -> "Bulleted list"
        BlockType.NUMBERED -> "Numbered list"
        BlockType.QUOTE -> "Quote"
        BlockType.CODE -> "Code"
        BlockType.DIVIDER -> "Divider"
        BlockType.IMAGE -> "Image"
    }

private fun placeholderFor(type: BlockType): String = when (type) {
    BlockType.HEADING1, BlockType.HEADING2, BlockType.HEADING3 -> "Heading"
    BlockType.TODO_ITEM -> "To-do"
    BlockType.CODE -> "Code"
    BlockType.QUOTE -> "Quote"
    else -> "Type something…"
}

private fun fontSizeFor(type: BlockType, base: androidx.compose.ui.unit.TextUnit) = when (type) {
    BlockType.HEADING1 -> base * 1.75f
    BlockType.HEADING2 -> base * 1.4f
    BlockType.HEADING3 -> base * 1.15f
    BlockType.CODE -> base * 0.92f
    else -> base
}
