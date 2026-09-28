package io.mynote.app.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.FormatListBulleted
import androidx.compose.material.icons.filled.FormatBold
import androidx.compose.material.icons.filled.FormatItalic
import androidx.compose.material.icons.filled.FormatStrikethrough
import androidx.compose.material.icons.filled.FormatUnderlined
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Code
import androidx.compose.material.icons.filled.FormatListNumbered
import androidx.compose.material.icons.filled.FormatQuote
import androidx.compose.material.icons.filled.HorizontalRule
import androidx.compose.material.icons.filled.Notes
import androidx.compose.material.icons.filled.Title
import androidx.compose.material.icons.filled.UnfoldMore
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MenuDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import io.mynote.app.theme.LocalMyNoteColors
import io.mynote.core.BlockType
import io.mynote.core.Mark

/**
 * The formatting controls above the keyboard.
 *
 * The long-press menu has always been able to change a block's type, but a menu
 * nobody knows to open is not a feature. This is the same set, in reach.
 */
@Composable
fun BlockFormatBar(
    current: BlockType,
    /** Marks the whole selection carries, shown as active. */
    activeMarks: Set<Mark>,
    onToggleMark: (Mark) -> Unit,
    onSelect: (BlockType) -> Unit,
    onDone: () -> Unit,
) {
    val colors = LocalMyNoteColors.current

    // Ordered for reach, not for the enum's sake: what people press constantly
    // sits nearest the left thumb.
    // Every type, matching iOS. The bar used to carry a subset, with the rest
    // hidden behind a ⋮ sitting next to every block — which is clutter on each
    // row for something needed occasionally. The bar scrolls; the ⋮ is gone.
    val items = listOf(
        BlockType.PARAGRAPH to Icons.Default.Notes,
        BlockType.HEADING1 to Icons.Default.Title,
        BlockType.HEADING2 to Icons.Default.Title,
        BlockType.HEADING3 to Icons.Default.Title,
        BlockType.BULLET to Icons.AutoMirrored.Filled.FormatListBulleted,
        BlockType.NUMBERED to Icons.Default.FormatListNumbered,
        BlockType.TODO_ITEM to Icons.Default.Check,
        BlockType.QUOTE to Icons.Default.FormatQuote,
        BlockType.CODE to Icons.Default.Code,
        BlockType.DIVIDER to Icons.Default.HorizontalRule,
    )

    // Inline marks come first: they are what gets pressed mid-sentence, and they
    // act on the selection rather than on the whole block.
    val marks = listOf(
        Mark.BOLD to Icons.Default.FormatBold,
        Mark.ITALIC to Icons.Default.FormatItalic,
        Mark.UNDERLINE to Icons.Default.FormatUnderlined,
        Mark.STRIKETHROUGH to Icons.Default.FormatStrikethrough,
    )

    Box(Modifier.fillMaxWidth().background(colors.surface)) {
        HorizontalDivider(color = colors.border)
        Row(
            Modifier.fillMaxWidth().height(48.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Row(
                Modifier
                    .weight(1f)
                    .horizontalScroll(rememberScrollState())
                    .padding(horizontal = 4.dp),
                horizontalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                for ((mark, icon) in marks) {
                    MarkButton(mark, icon, selected = mark in activeMarks) { onToggleMark(mark) }
                }

                Spacer(Modifier.width(4.dp))
                Box(Modifier.width(1.dp).height(24.dp).background(colors.border))
                Spacer(Modifier.width(4.dp))

                BlockStyleMenu(current, items, onSelect)
            }
            TextButton(onClick = onDone) { Text("Done", color = colors.accent) }
        }
    }
}

@Composable
private fun BlockStyleMenu(
    current: BlockType,
    items: List<Pair<BlockType, ImageVector>>,
    onSelect: (BlockType) -> Unit,
) {
    val colors = LocalMyNoteColors.current
    var open by remember { mutableStateOf(false) }

    Box {
        Row(
            Modifier
                .height(36.dp)
                .clip(RoundedCornerShape(8.dp))
                .background(colors.textSecondary.copy(alpha = 0.12f))
                .clickable { open = true }
                .padding(horizontal = 10.dp)
                .semantics { contentDescription = "Block style, ${current.label}" },
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(5.dp),
        ) {
            Icon(iconFor(current, items), null, tint = colors.textPrimary,
                 modifier = Modifier.size(18.dp))
            Text(current.label, color = colors.textPrimary, fontSize = 15.sp)
            Icon(Icons.Default.UnfoldMore, null, tint = colors.textSecondary,
                 modifier = Modifier.size(14.dp))
        }

        // Themed explicitly. A DropdownMenu otherwise paints itself from the
        // Material colour scheme, which is not the theme the user picked — so a
        // custom theme stopped at the edge of this menu.
        DropdownMenu(
            expanded = open,
            onDismissRequest = { open = false },
            modifier = Modifier.background(colors.surface),
        ) {
            for ((type, icon) in items) {
                DropdownMenuItem(
                    text = { Text(type.label, fontSize = 15.sp) },
                    onClick = { onSelect(type); open = false },
                    leadingIcon = { Icon(icon, null, modifier = Modifier.size(20.dp)) },
                    trailingIcon = {
                        if (type == current) Icon(Icons.Default.Check, null, tint = colors.accent)
                    },
                    colors = MenuDefaults.itemColors(
                        textColor = colors.textPrimary,
                        leadingIconColor = if (type == current) colors.accent else colors.textSecondary,
                        trailingIconColor = colors.accent,
                    ),
                )
            }
        }
    }
}

private fun iconFor(type: BlockType, items: List<Pair<BlockType, ImageVector>>) =
    items.first { it.first == type }.second



@Composable
private fun MarkButton(
    mark: Mark,
    icon: ImageVector,
    selected: Boolean,
    onClick: () -> Unit,
) {
    val colors = LocalMyNoteColors.current
    IconButton(
        onClick = onClick,
        modifier = Modifier
            .size(40.dp)
            .clip(RoundedCornerShape(8.dp))
            .background(if (selected) colors.accent.copy(alpha = 0.18f) else colors.surface)
            .semantics { contentDescription = mark.label },
    ) {
        Icon(icon, null, tint = if (selected) colors.accent else colors.textSecondary)
    }
}

val Mark.label: String
    get() = when (this) {
        Mark.BOLD -> "Bold"
        Mark.ITALIC -> "Italic"
        Mark.UNDERLINE -> "Underline"
        Mark.STRIKETHROUGH -> "Strikethrough"
    }
