import Testing
@testable import MyNoteCore

@Suite("Theme spec")
struct ThemeSpecTests {
    @Test("round-trips through JSON so themes survive sync")
    func roundTrip() throws {
        let theme = ThemeSpec.midnight
        let decoded = try #require(ThemeSpec.decode(theme.encoded()))
        #expect(decoded == theme)
    }

    @Test("every shipped preset has valid colours")
    func presetsAreValid() {
        for preset in ThemeSpec.presets {
            #expect(preset.sanitized() == preset, "\(preset.name) changed under sanitize")
            for hex in [preset.light.background, preset.light.accent,
                        preset.dark.background, preset.dark.accent] {
                #expect(ThemeSpec.validHex(hex) != nil, "\(preset.name): bad colour \(hex)")
            }
        }
    }

    @Test("replaces an invalid colour rather than rendering it")
    func rejectsBadColour() {
        var theme = ThemeSpec.defaultTheme
        theme.light.accent = "not-a-colour"
        theme.dark.background = "#GGGGGG"

        let clean = theme.sanitized()
        #expect(clean.light.accent == ThemeSpec.defaultTheme.light.accent)
        #expect(clean.dark.background == ThemeSpec.defaultTheme.dark.background)
    }

    @Test("clamps values that would make the app unreadable")
    func clampsExtremes() {
        var theme = ThemeSpec.defaultTheme
        theme.typography.baseSize = 0.5
        theme.typography.lineHeight = 99
        theme.layout.maxContentWidth = 10

        let clean = theme.sanitized()
        #expect(clean.typography.baseSize >= 11)
        #expect(clean.typography.lineHeight <= 2.5)
        #expect(clean.layout.maxContentWidth >= 320)
    }

    @Test("accepts 8-digit colours with alpha")
    func acceptsAlpha() {
        #expect(ThemeSpec.validHex("#11223344") == "#11223344")
        #expect(ThemeSpec.validHex("#112233") == "#112233")
        #expect(ThemeSpec.validHex("#1122") == nil)
        #expect(ThemeSpec.validHex("112233") == nil)
    }
}
