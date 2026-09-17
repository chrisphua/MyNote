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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import io.mynote.app.AppContainer
import io.mynote.app.theme.LocalMyNoteColors
import io.mynote.app.theme.LocalMyNoteMetrics
import io.mynote.app.theme.parseHex
import io.mynote.core.ThemeSpec
import java.util.Locale

/**
 * The paid feature itself: a live editor for every value in a `ThemeSpec`.
 *
 * Edits preview instantly against real content, because picking colours against
 * a blank swatch tells you nothing about how a page will actually read.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ThemeEditorScreen(
    container: AppContainer,
    initial: String?,
    onClose: () -> Unit,
    onSave: (ThemeSpec) -> Unit,
) {
    val colors = LocalMyNoteColors.current
    val metrics = LocalMyNoteMetrics.current
    val custom by container.themeState.custom.collectAsState()

    var draft by remember(initial) {
        mutableStateOf(
            custom.firstOrNull { it.id == initial } ?: container.themeState.draftFromCurrent()
        )
    }
    var editingDark by remember { mutableStateOf(false) }

    Scaffold(
        containerColor = colors.background,
        topBar = {
            TopAppBar(
                title = { Text("Edit theme", color = colors.textPrimary) },
                navigationIcon = {
                    IconButton(onClick = onClose) {
                        Icon(Icons.Default.Close, "Cancel", tint = colors.textSecondary)
                    }
                },
                actions = {
                    TextButton(
                        onClick = {
                            container.themeState.saveCustom(draft)?.let { saved ->
                                container.themeState.select(saved)
                                onSave(saved)
                            }
                        },
                        enabled = draft.name.isNotBlank(),
                    ) { Text("Save") }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = colors.background),
            )
        },
    ) { padding ->
        LazyColumn(
            modifier = Modifier.padding(padding).fillMaxSize().background(colors.background),
            contentPadding = PaddingValues(metrics.contentPadding),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            item {
                Column {
                    Label("Name")
                    BasicTextField(
                        value = draft.name,
                        onValueChange = { draft = draft.copy(name = it) },
                        singleLine = true,
                        textStyle = TextStyle(color = colors.textPrimary, fontSize = metrics.baseSize),
                        cursorBrush = SolidColor(colors.accent),
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(metrics.cornerRadius))
                            .background(colors.surface)
                            .padding(12.dp),
                    )
                }
            }

            item {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FilterChip(!editingDark, { editingDark = false }, { Text("Light") })
                    FilterChip(editingDark, { editingDark = true }, { Text("Dark") })
                }
            }

            item { LivePreview(draft, editingDark) }

            item { Label(if (editingDark) "Dark colours" else "Light colours") }
            items(PALETTE_SLOTS) { slot ->
                ColorRow(
                    label = slot.label,
                    hex = slot.get(if (editingDark) draft.dark else draft.light),
                    onPick = { hex ->
                        draft = if (editingDark) draft.copy(dark = slot.set(draft.dark, hex))
                        else draft.copy(light = slot.set(draft.light, hex))
                    },
                )
            }

            item { Label("Typography") }
            item {
                SliderRow("Text size", draft.typography.baseSize, 11.0, 28.0, "sp") {
                    draft = draft.copy(typography = draft.typography.copy(baseSize = it))
                }
            }
            item {
                SliderRow("Line height", draft.typography.lineHeight, 1.0, 2.5, "", decimals = 2) {
                    draft = draft.copy(typography = draft.typography.copy(lineHeight = it))
                }
            }
            item {
                SliderRow("Heading weight", draft.typography.headingWeight.toDouble(), 100.0, 900.0, "") {
                    draft = draft.copy(
                        typography = draft.typography.copy(headingWeight = (it / 100).toInt() * 100)
                    )
                }
            }

            item { Label("Layout") }
            item {
                SliderRow("Corner radius", draft.layout.cornerRadius, 0.0, 32.0, "dp") {
                    draft = draft.copy(layout = draft.layout.copy(cornerRadius = it))
                }
            }
            item {
                SliderRow("Page padding", draft.layout.contentPadding, 0.0, 48.0, "dp") {
                    draft = draft.copy(layout = draft.layout.copy(contentPadding = it))
                }
            }
            item {
                SliderRow("Block spacing", draft.layout.blockSpacing, 0.0, 32.0, "dp") {
                    draft = draft.copy(layout = draft.layout.copy(blockSpacing = it))
                }
            }
            item {
                SliderRow("Max page width", draft.layout.maxContentWidth, 320.0, 1400.0, "dp") {
                    draft = draft.copy(layout = draft.layout.copy(maxContentWidth = it))
                }
            }

            if (custom.any { it.id == draft.id }) {
                item {
                    TextButton(onClick = { container.themeState.deleteCustom(draft); onClose() }) {
                        Text("Delete theme", color = Color.Red)
                    }
                }
            }
        }
    }
}

private class PaletteSlot(
    val label: String,
    val get: (ThemeSpec.Palette) -> String,
    val set: (ThemeSpec.Palette, String) -> ThemeSpec.Palette,
)

private val PALETTE_SLOTS = listOf(
    PaletteSlot("Background", { it.background }, { p, v -> p.copy(background = v) }),
    PaletteSlot("Surface", { it.surface }, { p, v -> p.copy(surface = v) }),
    PaletteSlot("Text", { it.textPrimary }, { p, v -> p.copy(textPrimary = v) }),
    PaletteSlot("Secondary text", { it.textSecondary }, { p, v -> p.copy(textSecondary = v) }),
    PaletteSlot("Accent", { it.accent }, { p, v -> p.copy(accent = v) }),
    PaletteSlot("Border", { it.border }, { p, v -> p.copy(border = v) }),
    PaletteSlot("Code background", { it.codeBackground }, { p, v -> p.copy(codeBackground = v) }),
)

/**
 * Compose ships no colour picker, and pulling in a library for one screen is a
 * poor trade. A swatch grid plus a hex field covers both the quick pick and the
 * "I have a brand colour" case.
 */
private val SWATCHES = listOf(
    "#FFFFFF", "#F7F7F5", "#EDEDEC", "#9B9B96", "#6B6B66", "#3A3A38", "#191919", "#000000",
    "#2F6FED", "#6C9BFF", "#4A5CF0", "#7B8BFF", "#0F9D58", "#34C759", "#A8601F", "#D89A4E",
    "#E4572E", "#FF375F", "#AF52DE", "#5856D6", "#FBF3E4", "#241E16", "#0E1119", "#E6EAF5",
)

@Composable
private fun ColorRow(label: String, hex: String, onPick: (String) -> Unit) {
    val colors = LocalMyNoteColors.current
    val metrics = LocalMyNoteMetrics.current
    var expanded by remember { mutableStateOf(false) }
    var hexField by remember(hex) { mutableStateOf(hex) }

    Column(Modifier.fillMaxWidth()) {
        Row(
            Modifier.fillMaxWidth().clickable { expanded = !expanded }.padding(vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                Modifier
                    .size(24.dp)
                    .clip(CircleShape)
                    .background(parseHex(hex) ?: colors.surface)
            )
            Spacer(Modifier.width(10.dp))
            Text(label, color = colors.textPrimary, modifier = Modifier.weight(1f))
            Text(hex, color = colors.textSecondary, fontFamily = FontFamily.Monospace,
                 fontSize = metrics.baseSize * 0.82f)
        }

        if (expanded) {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                SWATCHES.chunked(8).forEach { rowColors ->
                    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        rowColors.forEach { swatch ->
                            Box(
                                Modifier
                                    .size(28.dp)
                                    .clip(CircleShape)
                                    .background(parseHex(swatch) ?: colors.surface)
                                    .clickable { hexField = swatch; onPick(swatch) }
                            )
                        }
                    }
                }
                BasicTextField(
                    value = hexField,
                    onValueChange = { typed ->
                        hexField = typed
                        // Only commit a value that parses, so a half-typed hex
                        // never flashes the whole app to a fallback colour.
                        ThemeSpec.validHex(typed)?.let(onPick)
                    },
                    singleLine = true,
                    textStyle = TextStyle(
                        color = colors.textPrimary,
                        fontFamily = FontFamily.Monospace,
                        fontSize = metrics.baseSize * 0.9f,
                    ),
                    cursorBrush = SolidColor(colors.accent),
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(metrics.cornerRadius))
                        .background(colors.surface)
                        .padding(10.dp),
                )
            }
        }
    }
}

@Composable
private fun SliderRow(
    label: String,
    value: Double,
    min: Double,
    max: Double,
    unit: String,
    decimals: Int = 0,
    onChange: (Double) -> Unit,
) {
    val colors = LocalMyNoteColors.current
    val metrics = LocalMyNoteMetrics.current

    Column(Modifier.fillMaxWidth()) {
        Row {
            Text(label, color = colors.textPrimary, modifier = Modifier.weight(1f))
            Text(
                String.format(Locale.US, "%.${decimals}f%s", value, unit),
                color = colors.textSecondary,
                fontFamily = FontFamily.Monospace,
                fontSize = metrics.baseSize * 0.82f,
            )
        }
        Slider(
            value = value.toFloat(),
            onValueChange = { onChange(it.toDouble()) },
            valueRange = min.toFloat()..max.toFloat(),
        )
    }
}

@Composable
private fun Label(text: String) {
    val colors = LocalMyNoteColors.current
    val metrics = LocalMyNoteMetrics.current
    Text(text, color = colors.textSecondary, fontSize = metrics.baseSize * 0.82f)
}

/** Renders real blocks, not colour chips, so the effect of a change is honest. */
@Composable
private fun LivePreview(spec: ThemeSpec, dark: Boolean) {
    val clean = spec.sanitized()
    val palette = if (dark) clean.dark else clean.light
    val bg = parseHex(palette.background) ?: Color.White
    val text = parseHex(palette.textPrimary) ?: Color.Black
    val secondary = parseHex(palette.textSecondary) ?: Color.Gray
    val accent = parseHex(palette.accent) ?: Color.Blue
    val code = parseHex(palette.codeBackground) ?: Color.LightGray
    val radius = clean.layout.cornerRadius.dp
    val base = clean.typography.baseSize.sp

    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(radius))
            .background(bg)
            .padding(clean.layout.contentPadding.dp),
        verticalArrangement = Arrangement.spacedBy(clean.layout.blockSpacing.dp),
    ) {
        Text("Weekend plans", color = text, fontSize = base * 1.75f,
             fontWeight = androidx.compose.ui.text.font.FontWeight(clean.typography.headingWeight))
        Text(
            "Body text sits at the size and line height you picked, so you can judge a long paragraph rather than a single word.",
            color = text,
            fontSize = base,
            lineHeight = (clean.typography.baseSize * clean.typography.lineHeight).sp,
        )
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(14.dp).clip(RoundedCornerShape(3.dp)).background(accent))
            Spacer(Modifier.width(8.dp))
            Text("A finished to-do", color = text, fontSize = base)
        }
        Text(
            "val greeting = \"hello\"",
            color = text,
            fontSize = base * 0.92f,
            fontFamily = FontFamily.Monospace,
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(radius))
                .background(code)
                .padding(10.dp),
        )
        Text("Secondary text, for dates and captions.", color = secondary, fontSize = base * 0.82f)
    }
}
