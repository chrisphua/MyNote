import Testing
import SwiftUI
@testable import MyNote
import MyNoteCore

@Suite("Theme rendering")
@MainActor
struct ThemeRenderingTests {
    @Test("parses the hex forms a theme can contain")
    func parsesHex() {
        #expect(UIColor(hex: "#FFFFFF") != nil)
        #expect(UIColor(hex: "FFFFFF") != nil)
        #expect(UIColor(hex: "#FFFFFFAA") != nil)
        #expect(UIColor(hex: "#FFF") == nil)
        #expect(UIColor(hex: "nonsense") == nil)
    }

    @Test("a hostile theme still renders")
    func survivesBadInput() {
        var spec = ThemeSpec.defaultTheme
        spec.light.background = "javascript:alert(1)"
        spec.typography.baseSize = -100
        spec.layout.maxContentWidth = 0

        let theme = Theme(spec: spec)
        #expect(theme.spec.light.background == ThemeSpec.defaultTheme.light.background)
        #expect(theme.spec.typography.baseSize >= 11)
        #expect(theme.maxContentWidth >= 320)
    }

    @Test("custom themes are gated behind the purchase")
    func themeGate() {
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        let manager = ThemeManager(defaults: defaults)

        manager.canEdit = false
        #expect(manager.saveCustom(ThemeSpec.defaultTheme) == nil,
                "an unpaid user must not be able to save a custom theme")

        manager.canEdit = true
        var draft = manager.draftFromCurrent()
        draft.name = "Mine"
        #expect(manager.saveCustom(draft) != nil)
        #expect(manager.customThemes.count == 1)
    }

    @Test("presets are always available without paying")
    func presetsFree() {
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        let manager = ThemeManager(defaults: defaults)
        manager.canEdit = false

        #expect(manager.allThemes.count >= 3)
        manager.select(ThemeSpec.midnight)
        #expect(manager.current.spec.id == ThemeSpec.midnight.id)
    }
}
