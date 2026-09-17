import Foundation
import SwiftUI
import MyNoteCore

/// Holds the active theme and the user's custom ones.
///
/// Presets are free. Creating, editing or importing a theme requires the
/// `theme_pro` entitlement — that gate lives in `canEdit`, and the UI asks here
/// rather than checking receipts itself.
@Observable
@MainActor
final class ThemeManager {
    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var label: String {
            switch self {
            case .system: "Match device"
            case .light:  "Always light"
            case .dark:   "Always dark"
            }
        }
    }

    private(set) var current: Theme
    private(set) var customThemes: [ThemeSpec] = []
    var appearance: Appearance {
        didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) }
    }

    /// Flipped by the purchase manager; themes stay selectable but not editable.
    var canEdit = false

    private let defaults: UserDefaults
    private enum Keys {
        static let selected = "theme.selectedId"
        static let appearance = "theme.appearance"
        static let custom = "theme.custom"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.appearance = Appearance(
            rawValue: defaults.string(forKey: Keys.appearance) ?? ""
        ) ?? .system

        // Built into locals first: Swift will not let us read a stored property
        // back out of `self` until every one of them has a value.
        var loadedCustom: [ThemeSpec] = []
        if let data = defaults.data(forKey: Keys.custom),
           let decoded = try? JSONDecoder().decode([ThemeSpec].self, from: data) {
            loadedCustom = decoded.map { $0.sanitized() }
        }
        self.customThemes = loadedCustom

        let selectedId = defaults.string(forKey: Keys.selected) ?? ThemeSpec.defaultTheme.id
        let spec = (ThemeSpec.presets + loadedCustom).first { $0.id == selectedId }
            ?? ThemeSpec.defaultTheme
        self.current = Theme(spec: spec)
    }

    var allThemes: [ThemeSpec] { ThemeSpec.presets + customThemes }

    var colorSchemeOverride: ColorScheme? {
        switch appearance {
        case .system: nil
        case .light:  .light
        case .dark:   .dark
        }
    }

    func select(_ spec: ThemeSpec) {
        current = Theme(spec: spec.sanitized())
        defaults.set(spec.id, forKey: Keys.selected)
    }

    /// Returns nil when the user has not paid — the caller shows the paywall.
    @discardableResult
    func saveCustom(_ spec: ThemeSpec) -> ThemeSpec? {
        guard canEdit else { return nil }
        var clean = spec.sanitized()
        clean.isPreset = false

        if let index = customThemes.firstIndex(where: { $0.id == clean.id }) {
            customThemes[index] = clean
        } else {
            customThemes.append(clean)
        }
        persistCustom()
        if current.spec.id == clean.id { current = Theme(spec: clean) }
        return clean
    }

    func deleteCustom(_ spec: ThemeSpec) {
        customThemes.removeAll { $0.id == spec.id }
        persistCustom()
        if current.spec.id == spec.id { select(ThemeSpec.defaultTheme) }
    }

    /// Adopt custom themes pulled from another device.
    ///
    /// Themes sync as ordinary records; this is where they join the picker. A
    /// synced theme wins over the local copy of the same id, because sync has
    /// already resolved which version is newer.
    func mergeSynced(_ specs: [ThemeSpec]) {
        guard !specs.isEmpty else { return }
        var merged = customThemes
        for spec in specs {
            let clean = spec.sanitized()
            if let index = merged.firstIndex(where: { $0.id == clean.id }) {
                merged[index] = clean
            } else {
                merged.append(clean)
            }
        }
        customThemes = merged
        persistCustom()

        // Keep showing the selected theme if its definition just changed.
        if let refreshed = merged.first(where: { $0.id == current.spec.id }) {
            current = Theme(spec: refreshed)
        }
    }

    /// Drop everything custom — used when the signed-in account changes.
    func forgetSyncedThemes() {
        customThemes = []
        persistCustom()
        select(ThemeSpec.defaultTheme)
    }

    /// Start a new theme from whatever is on screen, so editing feels like
    /// tweaking rather than building from nothing.
    func draftFromCurrent() -> ThemeSpec {
        var draft = current.spec
        draft.id = UUID().uuidString
        draft.name = draft.isPreset ? "\(draft.name) Custom" : draft.name
        draft.isPreset = false
        return draft
    }

    private func persistCustom() {
        if let data = try? JSONEncoder().encode(customThemes) {
            defaults.set(data, forKey: Keys.custom)
        }
    }
}
