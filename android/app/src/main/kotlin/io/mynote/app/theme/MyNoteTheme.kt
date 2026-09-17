package io.mynote.app.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import io.mynote.core.ThemeSpec

/** Parse `#RRGGBB` / `#RRGGBBAA`; returns null rather than a wrong colour. */
fun parseHex(hex: String): Color? {
    val value = ThemeSpec.validHex(hex) ?: return null
    val body = value.drop(1)
    val raw = body.toLongOrNull(16) ?: return null
    return if (body.length == 8) {
        Color(
            red = ((raw shr 24) and 0xFF) / 255f,
            green = ((raw shr 16) and 0xFF) / 255f,
            blue = ((raw shr 8) and 0xFF) / 255f,
            alpha = (raw and 0xFF) / 255f,
        )
    } else {
        Color(
            red = ((raw shr 16) and 0xFF) / 255f,
            green = ((raw shr 8) and 0xFF) / 255f,
            blue = (raw and 0xFF) / 255f,
        )
    }
}

/**
 * A `ThemeSpec` resolved into Compose values.
 *
 * Held in a CompositionLocal rather than squeezed into MaterialTheme, because a
 * user theme carries values Material has no slot for (block spacing, page width)
 * and must round-trip byte-identically with iOS.
 */
data class MyNoteColors(
    val background: Color,
    val surface: Color,
    val textPrimary: Color,
    val textSecondary: Color,
    val accent: Color,
    val border: Color,
    val codeBackground: Color,
)

data class MyNoteMetrics(
    val cornerRadius: Dp,
    val contentPadding: Dp,
    val blockSpacing: Dp,
    val maxContentWidth: Dp,
    val baseSize: TextUnit,
    val lineHeight: TextUnit,
    val headingWeight: FontWeight,
)

val LocalMyNoteColors = staticCompositionLocalOf {
    paletteToColors(ThemeSpec.defaultTheme.light)
}
val LocalMyNoteMetrics = staticCompositionLocalOf {
    specToMetrics(ThemeSpec.defaultTheme)
}

private fun paletteToColors(p: ThemeSpec.Palette): MyNoteColors {
    val fallback = ThemeSpec.defaultTheme.light
    return MyNoteColors(
        background = parseHex(p.background) ?: parseHex(fallback.background)!!,
        surface = parseHex(p.surface) ?: parseHex(fallback.surface)!!,
        textPrimary = parseHex(p.textPrimary) ?: parseHex(fallback.textPrimary)!!,
        textSecondary = parseHex(p.textSecondary) ?: parseHex(fallback.textSecondary)!!,
        accent = parseHex(p.accent) ?: parseHex(fallback.accent)!!,
        border = parseHex(p.border) ?: parseHex(fallback.border)!!,
        codeBackground = parseHex(p.codeBackground) ?: parseHex(fallback.codeBackground)!!,
    )
}

private fun specToMetrics(spec: ThemeSpec): MyNoteMetrics {
    val clean = spec.sanitized()
    return MyNoteMetrics(
        cornerRadius = clean.layout.cornerRadius.dp,
        contentPadding = clean.layout.contentPadding.dp,
        blockSpacing = clean.layout.blockSpacing.dp,
        maxContentWidth = clean.layout.maxContentWidth.dp,
        baseSize = clean.typography.baseSize.sp,
        lineHeight = (clean.typography.baseSize * clean.typography.lineHeight).sp,
        headingWeight = FontWeight(clean.typography.headingWeight),
    )
}

@Composable
fun MyNoteTheme(
    spec: ThemeSpec,
    darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit,
) {
    val clean = spec.sanitized()
    val colors = paletteToColors(if (darkTheme) clean.dark else clean.light)
    val metrics = specToMetrics(clean)

    // Material components (dialogs, pickers, switches) still need a scheme, so
    // the user's palette is mapped onto one instead of leaving them default.
    val scheme = if (darkTheme) {
        darkColorScheme(
            primary = colors.accent, background = colors.background, surface = colors.surface,
            onBackground = colors.textPrimary, onSurface = colors.textPrimary,
            outline = colors.border, surfaceVariant = colors.surface,
        )
    } else {
        lightColorScheme(
            primary = colors.accent, background = colors.background, surface = colors.surface,
            onBackground = colors.textPrimary, onSurface = colors.textPrimary,
            outline = colors.border, surfaceVariant = colors.surface,
        )
    }

    // `sp` keeps the user's system font-size setting working, so a custom theme
    // can never break accessibility text scaling.
    val typography = Typography(
        bodyLarge = TextStyle(
            fontFamily = FontFamily.Default,
            fontSize = metrics.baseSize,
            lineHeight = metrics.lineHeight,
        ),
        headlineLarge = TextStyle(
            fontFamily = FontFamily.Default,
            fontSize = metrics.baseSize * 1.75f,
            fontWeight = metrics.headingWeight,
        ),
        headlineMedium = TextStyle(
            fontFamily = FontFamily.Default,
            fontSize = metrics.baseSize * 1.4f,
            fontWeight = metrics.headingWeight,
        ),
        headlineSmall = TextStyle(
            fontFamily = FontFamily.Default,
            fontSize = metrics.baseSize * 1.15f,
            fontWeight = metrics.headingWeight,
        ),
        bodySmall = TextStyle(
            fontFamily = FontFamily.Default,
            fontSize = metrics.baseSize * 0.82f,
        ),
    )

    CompositionLocalProvider(
        LocalMyNoteColors provides colors,
        LocalMyNoteMetrics provides metrics,
    ) {
        MaterialTheme(colorScheme = scheme, typography = typography, content = content)
    }
}
