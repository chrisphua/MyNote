package io.mynote.app.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.union
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.CheckBox
import androidx.compose.material.icons.filled.CheckBoxOutlineBlank
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
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.unit.dp
import io.mynote.app.AppContainer
import io.mynote.app.data.BlockRow
import io.mynote.app.theme.LocalMyNoteColors
import io.mynote.app.theme.LocalMyNoteMetrics
import io.mynote.core.Block
import io.mynote.core.BlockContent
import io.mynote.core.BlockType
import io.mynote.core.InlineSpans
import io.mynote.core.Mark
import io.mynote.core.Span
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

    // Sorted here as well as in SQL. A fractional index is only meaningful under
    // code-point comparison, and Kotlin's String ordering is exactly that —
    // whereas a store's collation may not be. iOS shipped blocks in the wrong
    // order for precisely this reason.
    val ordered = remember(blocks) { blocks.sortedBy { it.orderKey } }
    // The block the formatting bar acts on: the one being edited, and after
    // focus leaves, still the one that was. Clearing this the moment the field
    // lost focus took the bar off screen between the press and the release of
    // its own buttons, so the press never became a click and nothing happened.
    var activeBlockId by remember(noteId) { mutableStateOf<String?>(null) }
    // Where typing should continue after an edit that moved it. Splitting a
    // block is only half the behaviour; without this the caret stayed in the
    // block above and the next keystroke went to the wrong one.
    var caret by remember(noteId) { mutableStateOf<CaretRequest?>(null) }
    // The selection inside the active block, in UTF-16 offsets — what the mark
    // buttons act on and what decides which of them look active.
    var selection by remember(noteId) { mutableStateOf(0 to 0) }
    val focusManager = LocalFocusManager.current
    val listState = rememberLazyListState()

    // Bring the target into view before it is asked for the caret.
    //
    // The list is lazy, so a block outside the composed window does not exist
    // yet and cannot take focus — and the caret stayed in the block above.
    // Pressing Return five times near the end of a long note left five empty
    // blocks behind and typed all five lines into the original one.
    // Keyed on `ordered` as well: the caret is aimed the moment the repository
    // call returns, which is usually before the store has emitted the new row —
    // so the first run often cannot find the target at all, and keying on the
    // request alone meant it was never looked for again.
    LaunchedEffect(caret, ordered) {
        val target = caret ?: return@LaunchedEffect
        val index = ordered.indexOfFirst { it.id == target.blockId }
        if (index < 0) return@LaunchedEffect
        // +1: the title occupies the first item.
        val item = index + 1
        if (listState.layoutInfo.visibleItemsInfo.none { it.index == item }) {
            listState.scrollToItem(item)
        }
    }

    Scaffold(
        // The window is edge-to-edge, so `adjustResize` does not shrink it and
        // the keyboard simply covers whatever is at the bottom — which is the
        // formatting bar. Holding the whole screen above the IME is what puts
        // the bar back on screen; without it the controls existed but nobody
        // could ever see or press them.
        modifier = Modifier.windowInsetsPadding(
            WindowInsets.ime.union(WindowInsets.navigationBars).only(WindowInsetsSides.Bottom)
        ),
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
                            val id = container.repository.appendBlock(noteId, ordered.lastOrNull()?.orderKey)
                            caret = CaretRequest(id, CaretRequest.END)
                        }
                    }) {
                        Icon(Icons.Default.Add, "Add block", tint = colors.accent)
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = colors.background),
            )
        },
        bottomBar = {
            val active = ordered.firstOrNull { it.id == activeBlockId }
            if (active != null) {
                val activeContent = BlockContent.decode(active.content)
                val activeMarks = InlineSpans.marks(
                    selection.first, selection.second,
                    activeContent.inlineSpans, activeContent.text.length,
                )
                BlockFormatBar(
                    current = BlockType.fromWire(active.type) ?: BlockType.PARAGRAPH,
                    activeMarks = activeMarks,
                    onToggleMark = { mark ->
                        val length = activeContent.text.length
                        val from = selection.first.coerceIn(0, length)
                        val to = selection.second.coerceIn(from, length)
                        // Nothing selected, nothing to mark.
                        if (from < to) {
                            scope.launch {
                                val updated = InlineSpans.toggle(
                                    mark, from, to, activeContent.inlineSpans, length,
                                )
                                container.repository.blockById(active.id)?.let { fresh ->
                                    container.repository.update(
                                        fresh.copy(content = fresh.content.withSpans(updated))
                                    )
                                }
                            }
                        }
                    },
                    onSelect = { type ->
                        scope.launch {
                            container.repository.setBlockType(active.id, type)
                            // Hand the caret back, so changing a block's type
                            // does not also end the sentence.
                            caret = CaretRequest(active.id, CaretRequest.END)
                        }
                    },
                    onDone = {
                        focusManager.clearFocus()
                        activeBlockId = null
                    },
                )
            }
        },
    ) { padding ->
        Box(Modifier.padding(padding).fillMaxSize().background(colors.background)) {
            LazyColumn(
                state = listState,
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

                items(ordered, key = { it.id }) { row ->
                    BlockEditor(
                        row = row,
                        caret = caret?.takeIf { it.blockId == row.id },
                        onCaretPlaced = { placed -> if (caret?.blockId == placed) caret = null },
                        onChange = { updated -> scope.launch { container.repository.update(updated) } },
                        onSplit = { before, after ->
                            scope.launch {
                                val next = ordered.firstOrNull { it.orderKey > row.orderKey }?.orderKey
                                row.asDomain()?.let {
                                    val id = container.repository.splitBlock(it, before, after, next)
                                    // Typing continues at the start of what was
                                    // carried down, as it does on iOS.
                                    caret = CaretRequest(id, 0)
                                }
                            }
                        },
                        onMergeBackwards = {
                            scope.launch {
                                // A divider holds no text field, so folding text
                                // into one would put it somewhere the writer can
                                // never reach it again — and then asking it for
                                // the caret brought the app down. Merge into the
                                // nearest block that can actually hold text.
                                val previous = ordered.lastOrNull {
                                    it.orderKey < row.orderKey && it.holdsText
                                }
                                val block = container.repository.blockById(row.id) ?: return@launch
                                if (previous == null) {
                                    // Already the first block. Backspacing out of a
                                    // list or heading turns it back into plain text,
                                    // which is the usual way out of a style applied
                                    // by accident.
                                    if (block.type != BlockType.PARAGRAPH) {
                                        container.repository.setBlockType(block.id, BlockType.PARAGRAPH)
                                    }
                                } else {
                                    container.repository.blockById(previous.id)?.let { above ->
                                        val offset = container.repository.mergeIntoPrevious(block, above)
                                        // The caret sits where the two texts
                                        // join, so backspace is undone by
                                        // typing. The joined text travels with
                                        // it: the block above is about to take
                                        // focus, and a focused field does not
                                        // accept text from the store.
                                        caret = CaretRequest(
                                            blockId = above.id,
                                            offset = offset,
                                            text = above.content.text + block.content.text,
                                        )
                                    }
                                }
                            }
                        },
                        onFocusChange = { focused -> if (focused) activeBlockId = row.id },
                        onSelectionChange = { start, end -> selection = start to end },
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
                                    val id = container.repository.appendBlock(noteId, ordered.lastOrNull()?.orderKey)
                                    caret = CaretRequest(id, CaretRequest.END)
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
    // Non-null when this block is the one typing should move into.
    caret: CaretRequest?,
    onCaretPlaced: (String) -> Unit,
    onChange: (Block) -> Unit,
    // Return pressed, carrying the text either side of the caret.
    onSplit: (String, String) -> Unit,
    // Backspace pressed with the caret at the very start.
    onMergeBackwards: () -> Unit,
    onFocusChange: (Boolean) -> Unit,
    onSelectionChange: (Int, Int) -> Unit,
) {
    val colors = LocalMyNoteColors.current
    val metrics = LocalMyNoteMetrics.current

    val type = BlockType.fromWire(row.type) ?: BlockType.PARAGRAPH
    val content = remember(row.content) { BlockContent.decode(row.content) }
    // A TextFieldValue rather than a String: the caret position is what decides
    // whether backspace deletes a character or folds this block into the one
    // above, and a plain String does not carry it.
    var field by remember(row.id) { mutableStateOf(TextFieldValue(content.text)) }
    var spans by remember(row.id) { mutableStateOf(content.inlineSpans) }
    val text = field.text
    var isFocused by remember(row.id) { mutableStateOf(false) }
    val focusRequester = remember(row.id) { FocusRequester() }

    LaunchedEffect(caret) {
        val request = caret ?: return@LaunchedEffect
        val body = request.text ?: field.text
        val target =
            if (request.offset == CaretRequest.END) body.length
            else request.offset.coerceIn(0, body.length)
        field = TextFieldValue(body, TextRange(target))
        // A block type that renders no text field has no requester attached, and
        // requesting focus on one throws. Nothing above should aim the caret at
        // such a block, but a crash in the editor is far worse than a caret that
        // does not move.
        runCatching { focusRequester.requestFocus() }
        onCaretPlaced(row.id)
    }

    LaunchedEffect(row.content) {
        // Ownership decides this: while the field has focus it owns its text,
        // so a write echoing back from the store cannot reach the screen. Once
        // focus leaves, the store is authoritative.
        //
        // The guard has to be ownership and not a comparison against the last
        // text written. Every keystroke is a separate write, and the echoes
        // arrive behind the typing — so "is this different from what I last
        // sent?" is true for every stale echo in the queue, and adopting one
        // rewinds the field. Typing "first" came back as "fir".
        //
        // An edit that genuinely replaces this field's text while it is focused
        // — folding the block below into this one — therefore cannot arrive
        // this way. It arrives in the caret request instead, which carries the
        // text with it and does not depend on when the store catches up.
        val decoded = BlockContent.decode(row.content)
        val incoming = decoded.text

        // Formatting is not text. A toolbar press changes how the words look
        // and leaves the words alone, and the ownership rule below exists to
        // protect the words — so when the text matches, the formatting is safe
        // to take even while this block is being edited.
        if (incoming == field.text) {
            if (decoded.inlineSpans != spans) spans = decoded.inlineSpans
            return@LaunchedEffect
        }

        if (!isFocused) {
            field = field.copy(text = incoming)
            spans = decoded.inlineSpans
        }
    }

    fun emit(
        newText: String = text,
        newContent: BlockContent = content,
        newType: BlockType = type,
        newSpans: List<Span> = spans,
    ) {
        onChange(
            Block(
                id = row.id,
                noteId = row.noteId,
                parentId = row.parentId,
                orderKey = row.orderKey,
                type = newType,
                content = newContent.copy(text = newText)
                    .withSpans(InlineSpans.normalized(newSpans, newText.length)),
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
                // Styled on the way in, plain on the way out: Compose reports an
                // edit as a plain string, so the spans are the record and this
                // is only how they look.
                value = field.copy(annotatedString = annotated(field.text, spans, colors.accent)),
                onValueChange = { newValue ->
                    // Return splits the block rather than inserting a newline. A
                    // block editor has no use for a line break inside a
                    // paragraph — that is what the next block is for.
                    //
                    // Only a newline that was just typed counts. Scanning the
                    // whole value for one split the block again on every
                    // keystroke if its text already contained a line break —
                    // which it can, because a paste keeps them and iOS stores
                    // them verbatim, so such a block arrives over sync.
                    val caretPos = newValue.selection.start
                    val typedReturn = caretPos in 1..newValue.text.length &&
                        newValue.text[caretPos - 1] == '\n'
                    if (typedReturn) {
                        val newline = caretPos - 1
                        val head = newValue.text.substring(0, newline)
                        // Adopt the head immediately. The store write below is
                        // async, and `LaunchedEffect(row.content)` deliberately
                        // ignores echoes while this field has focus — so without
                        // this the block would keep showing the whole pre-split
                        // string until the note was reopened.
                        field = TextFieldValue(head, TextRange(head.length))
                        spans = InlineSpans.slice(spans, text.length, 0, head.length)
                        onSplit(head, newValue.text.substring(newline + 1))
                    } else {
                        // Compose hands back the finished text and not the edit,
                        // so the edit is recovered by comparing — that is what
                        // keeps a bold run bold as the words around it change.
                        val moved = InlineSpans.adjustedForEdit(spans, field.text, newValue.text)
                        field = newValue
                        spans = moved
                        onSelectionChange(newValue.selection.start, newValue.selection.end)
                        emit(newText = newValue.text, newSpans = moved)
                    }
                },
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
                    .focusRequester(focusRequester)
                    .onFocusChanged {
                        isFocused = it.isFocused
                        onFocusChange(it.isFocused)
                        if (it.isFocused) onSelectionChange(field.selection.start, field.selection.end)
                    }
                    // Backspace with the caret at the very start folds this block
                    // into the one above. When the field is empty there is nothing
                    // to delete, so no text change is reported and this key event
                    // is the only signal there is.
                    .onPreviewKeyEvent { event ->
                        val atStart = field.selection.collapsed && field.selection.start == 0
                        if (event.type == KeyEventType.KeyDown &&
                            event.key == Key.Backspace &&
                            atStart
                        ) {
                            onMergeBackwards()
                            true
                        } else {
                            false
                        }
                    },
            )
        }

    }
}

/**
 * A request to put the caret in a particular block.
 *
 * Splitting, merging and deleting all move where typing should continue, and
 * each knows the offset it wants: the start of the carried-down text, the point
 * two blocks were joined, or the end of whatever is there.
 */
private data class CaretRequest(
    val blockId: String,
    val offset: Int,
    /**
     * Text to put in the block as the caret lands, when the move also replaced
     * what was there — a merge. Null means leave the text alone and only move
     * the caret.
     */
    val text: String? = null,
) {
    companion object {
        const val END = -1
    }
}

/** Whether this row renders a text field the caret can land in. */
private val BlockRow.holdsText: Boolean
    get() = BlockType.fromWire(type) != BlockType.DIVIDER

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

/**
 * Prompt shown in an empty block.
 *
 * A plain paragraph shows nothing. An empty page that says "Type something…" is
 * telling the writer what they already came to do, and it sits there on every
 * blank line of a long note.
 *
 * The others stay because they name a block type that is otherwise invisible
 * when empty — an empty heading and an empty quote look alike.
 */
private fun placeholderFor(type: BlockType): String = when (type) {
    BlockType.HEADING1, BlockType.HEADING2, BlockType.HEADING3 -> "Heading"
    BlockType.TODO_ITEM -> "To-do"
    BlockType.CODE -> "Code"
    BlockType.QUOTE -> "Quote"
    else -> ""
}

private fun fontSizeFor(type: BlockType, base: androidx.compose.ui.unit.TextUnit) = when (type) {
    BlockType.HEADING1 -> base * 1.75f
    BlockType.HEADING2 -> base * 1.4f
    BlockType.HEADING3 -> base * 1.15f
    BlockType.CODE -> base * 0.92f
    else -> base
}

/**
 * The block's text with its inline formatting applied.
 *
 * Rebuilt on each change rather than kept in the field: Compose hands an edit
 * back as plain text, so any styling carried on the value itself is lost the
 * moment someone types. The spans are the record; this is just how they look.
 */
private fun annotated(text: String, spans: List<Span>, linkColor: Color): AnnotatedString =
    AnnotatedString.Builder(text).apply {
        for (span in spans) {
            val start = span.start.coerceIn(0, text.length)
            val end = span.end.coerceIn(start, text.length)
            if (start >= end) continue
            addStyle(
                SpanStyle(
                    fontWeight = if (Mark.BOLD in span.marks) FontWeight.Bold else null,
                    fontStyle = if (Mark.ITALIC in span.marks) FontStyle.Italic else null,
                    color = if (span.link != null) linkColor else Color.Unspecified,
                    textDecoration = decorationFor(span),
                ),
                start,
                end,
            )
        }
    }.toAnnotatedString()

private fun decorationFor(span: Span): TextDecoration? {
    val lines = buildList {
        if (Mark.UNDERLINE in span.marks || span.link != null) add(TextDecoration.Underline)
        if (Mark.STRIKETHROUGH in span.marks) add(TextDecoration.LineThrough)
    }
    return when {
        lines.isEmpty() -> null
        lines.size == 1 -> lines.first()
        else -> TextDecoration.combine(lines)
    }
}

/** The stored row as the domain type the repository works in. */
private fun BlockRow.asDomain(): Block? {
    val blockType = BlockType.fromWire(type) ?: return null
    return Block(
        id = id,
        noteId = noteId,
        parentId = parentId,
        orderKey = orderKey,
        type = blockType,
        content = BlockContent.decode(content),
        hlc = hlc,
        deleted = deleted,
    )
}
