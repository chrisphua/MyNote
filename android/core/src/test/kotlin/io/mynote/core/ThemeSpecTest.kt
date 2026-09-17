package io.mynote.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ThemeSpecTest {

    @Test
    fun `round-trips through JSON so themes survive sync`() {
        val theme = ThemeSpec.midnight
        assertEquals(theme, ThemeSpec.decode(theme.encoded()))
    }

    @Test
    fun `every shipped preset has valid colours`() {
        for (preset in ThemeSpec.presets) {
            assertEquals("${preset.name} changed under sanitize", preset, preset.sanitized())
            for (hex in listOf(
                preset.light.background, preset.light.accent,
                preset.dark.background, preset.dark.accent,
            )) {
                assertNotNull("${preset.name}: bad colour $hex", ThemeSpec.validHex(hex))
            }
        }
    }

    @Test
    fun `presets match the iOS presets exactly`() {
        // The same theme must look identical on both platforms, so the ids and
        // the colour values are asserted rather than eyeballed.
        assertEquals("preset.default", ThemeSpec.defaultTheme.id)
        assertEquals("#2F6FED", ThemeSpec.defaultTheme.light.accent)
        assertEquals("#6C9BFF", ThemeSpec.defaultTheme.dark.accent)
        assertEquals("#A7997E", ThemeSpec.sepia.dark.textSecondary)
        assertEquals("#7B8BFF", ThemeSpec.midnight.dark.accent)
    }

    @Test
    fun `replaces an invalid colour rather than rendering it`() {
        val theme = ThemeSpec.defaultTheme.copy(
            light = ThemeSpec.defaultTheme.light.copy(accent = "not-a-colour"),
            dark = ThemeSpec.defaultTheme.dark.copy(background = "#GGGGGG"),
        )
        val clean = theme.sanitized()
        assertEquals(ThemeSpec.defaultTheme.light.accent, clean.light.accent)
        assertEquals(ThemeSpec.defaultTheme.dark.background, clean.dark.background)
    }

    @Test
    fun `clamps values that would make the app unreadable`() {
        val theme = ThemeSpec.defaultTheme.copy(
            typography = ThemeSpec.Typography(baseSize = 0.5, lineHeight = 99.0),
            layout = ThemeSpec.Layout(maxContentWidth = 10.0),
        )
        val clean = theme.sanitized()
        assertTrue(clean.typography.baseSize >= 11.0)
        assertTrue(clean.typography.lineHeight <= 2.5)
        assertTrue(clean.layout.maxContentWidth >= 320.0)
    }

    @Test
    fun `accepts 8-digit colours with alpha`() {
        assertEquals("#11223344", ThemeSpec.validHex("#11223344"))
        assertEquals("#112233", ThemeSpec.validHex("#112233"))
        assertNull(ThemeSpec.validHex("#1122"))
        assertNull(ThemeSpec.validHex("112233"))
    }
}
