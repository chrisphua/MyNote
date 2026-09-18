package io.mynote.app.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.FormatListBulleted
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Code
import androidx.compose.material.icons.filled.FormatQuote
import androidx.compose.material.icons.filled.HorizontalRule
import androidx.compose.material.icons.filled.Notes
import androidx.compose.material.icons.filled.Title
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import io.mynote.app.theme.LocalMyNoteColors
import io.mynote.core.BlockType

/**
 * The formatting controls above the keyboard.
 *
 * The long-press menu has always been able to change a block's type, but a menu
 * nobody knows to open is not a feature. This is the same set, in reach.
 */
@Composable
fun BlockFormatBar(
    current: BlockType,
    onSelect: (BlockType) -> Unit,
    onDone: () -> Unit,
) {
    val colors = LocalMyNoteColors.current

    // Ordered for reach, not for the enum's sake: what people press constantly
    // sits nearest the left thumb.
    val items = listOf(
        BlockType.PARAGRAPH to Icons.Default.Notes,
        BlockType.HEADING1 to Icons.Default.Title,
        BlockType.BULLET to Icons.AutoMirrored.Filled.FormatListBulleted,
        BlockType.TODO_ITEM to Icons.Default.Check,
        BlockType.QUOTE to Icons.Default.FormatQuote,
        BlockType.CODE to Icons.Default.Code,
        BlockType.DIVIDER to Icons.Default.HorizontalRule,
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
                for ((type, icon) in items) {
                    FormatButton(type, icon, selected = type == current) { onSelect(type) }
                }
            }
            TextButton(onClick = onDone) { Text("Done", color = colors.accent) }
        }
    }
}

@Composable
private fun FormatButton(
    type: BlockType,
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
            .semantics { contentDescription = type.label },
    ) {
        Icon(icon, null, tint = if (selected) colors.accent else colors.textSecondary)
    }
}
