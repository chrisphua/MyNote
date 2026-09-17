package io.mynote.core

import kotlinx.serialization.Serializable

/**
 * A complete visual theme, stored as JSON so it round-trips through sync and
 * stays identical on iOS and Android. Every value a user can change lives here —
 * this type *is* the paid feature.
 */
@Serializable
data class ThemeSpec(
    val id: String,
    val name: String,
    val light: Palette,
    val dark: Palette,
    val typography: Typography = Typography(),
    val layout: Layout = Layout(),
    val isPreset: Boolean = false,
) {
    @Serializable
    data class Palette(
        val background: String,
        val surface: String,
        val textPrimary: String,
        val textSecondary: String,
        val accent: String,
        val border: String,
        val codeBackground: String,
    ) {
        fun sanitized(fallback: Palette) = Palette(
            background = validHex(background) ?: fallback.background,
            surface = validHex(surface) ?: fallback.surface,
            textPrimary = validHex(textPrimary) ?: fallback.textPrimary,
            textSecondary = validHex(textSecondary) ?: fallback.textSecondary,
            accent = validHex(accent) ?: fallback.accent,
            border = validHex(border) ?: fallback.border,
            codeBackground = validHex(codeBackground) ?: fallback.codeBackground,
        )
    }

    @Serializable
    data class Typography(
        val fontFamily: String = "system",
        val baseSize: Double = 17.0,
        val lineHeight: Double = 1.45,
        val headingWeight: Int = 700,
    )

    @Serializable
    data class Layout(
        val cornerRadius: Double = 10.0,
        val contentPadding: Double = 16.0,
        val blockSpacing: Double = 6.0,
        /** Caps line length on tablets so text stays readable. */
        val maxContentWidth: Double = 720.0,
    )

    fun encoded(): String = MyNoteJson.encodeToString(serializer(), this)

    /**
     * Clamp a user-built theme into renderable ranges.
     *
     * A custom theme is arbitrary user input that may also arrive from another
     * device, so it is validated before reaching the renderer — an invalid colour
     * or a 0.1sp font must not be able to make the app unusable.
     */
    fun sanitized(): ThemeSpec = copy(
        name = name.take(60),
        light = light.sanitized(defaultTheme.light),
        dark = dark.sanitized(defaultTheme.dark),
        typography = typography.copy(
            baseSize = typography.baseSize.coerceIn(11.0, 28.0),
            lineHeight = typography.lineHeight.coerceIn(1.0, 2.5),
            headingWeight = typography.headingWeight.coerceIn(100, 900),
        ),
        layout = layout.copy(
            cornerRadius = layout.cornerRadius.coerceIn(0.0, 32.0),
            contentPadding = layout.contentPadding.coerceIn(0.0, 48.0),
            blockSpacing = layout.blockSpacing.coerceIn(0.0, 32.0),
            maxContentWidth = layout.maxContentWidth.coerceIn(320.0, 1400.0),
        ),
    )

    companion object {
        fun decode(raw: String): ThemeSpec? =
            runCatching { MyNoteJson.decodeFromString(serializer(), raw) }.getOrNull()

        fun validHex(value: String): String? {
            val trimmed = value.trim().uppercase()
            if (!trimmed.startsWith("#")) return null
            val body = trimmed.drop(1)
            if (body.length != 6 && body.length != 8) return null
            if (!body.all { it.isDigit() || it in 'A'..'F' }) return null
            return "#$body"
        }

        /** Free presets. Paying unlocks building your own, not using good ones. */
        val defaultTheme = ThemeSpec(
            id = "preset.default",
            name = "MyNote",
            light = Palette("#FFFFFF", "#F7F7F5", "#1A1A18", "#6B6B66", "#2F6FED", "#E4E4E0", "#F2F2EF"),
            dark = Palette("#191919", "#222222", "#EDEDEC", "#9B9B96", "#6C9BFF", "#2E2E2E", "#242424"),
            isPreset = true,
        )

        val sepia = ThemeSpec(
            id = "preset.sepia",
            name = "Sepia",
            light = Palette("#FBF3E4", "#F3E8D2", "#3B2F22", "#7A6A54", "#A8601F", "#E2D3B8", "#F0E4CC"),
            dark = Palette("#241E16", "#2E261C", "#EDE0CB", "#A7997E", "#D89A4E", "#3B3125", "#2A2219"),
            isPreset = true,
        )

        val midnight = ThemeSpec(
            id = "preset.midnight",
            name = "Midnight",
            light = Palette("#EEF1F8", "#E2E7F3", "#161B2B", "#5A6480", "#4A5CF0", "#CDD5E8", "#E6EAF5"),
            dark = Palette("#0E1119", "#161A26", "#E5E9F5", "#8D97B2", "#7B8BFF", "#222838", "#141824"),
            isPreset = true,
        )

        val presets = listOf(defaultTheme, sepia, midnight)
    }
}
