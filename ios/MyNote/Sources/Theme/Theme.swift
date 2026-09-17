import SwiftUI
import MyNoteCore

/// A `ThemeSpec` resolved into SwiftUI values.
///
/// Colours are built once here rather than parsed per view body, and every
/// colour is a dynamic `Color` that follows light/dark automatically, so one
/// theme covers both appearances without the views knowing which is active.
struct Theme: Equatable {
    let spec: ThemeSpec

    init(spec: ThemeSpec) {
        self.spec = spec.sanitized()
    }

    private func dynamic(_ light: String, _ dark: String) -> Color {
        Color(UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light) ?? .label
        })
    }

    var background: Color     { dynamic(spec.light.background, spec.dark.background) }
    var surface: Color        { dynamic(spec.light.surface, spec.dark.surface) }
    var textPrimary: Color    { dynamic(spec.light.textPrimary, spec.dark.textPrimary) }
    var textSecondary: Color  { dynamic(spec.light.textSecondary, spec.dark.textSecondary) }
    var accentColor: Color    { dynamic(spec.light.accent, spec.dark.accent) }
    var border: Color         { dynamic(spec.light.border, spec.dark.border) }
    var codeBackground: Color { dynamic(spec.light.codeBackground, spec.dark.codeBackground) }

    var cornerRadius: CGFloat { spec.layout.cornerRadius }
    var contentPadding: CGFloat { spec.layout.contentPadding }
    var blockSpacing: CGFloat { spec.layout.blockSpacing }
    var maxContentWidth: CGFloat { spec.layout.maxContentWidth }

    /// Body font. `.custom(..., relativeTo:)` keeps Dynamic Type working, so a
    /// custom theme can never break accessibility text sizing.
    func font(_ role: FontRole) -> Font {
        let size = spec.typography.baseSize * role.scale
        let base: Font = spec.typography.fontFamily == "system"
            ? .system(size: size, weight: role.weight(spec.typography.headingWeight), design: role.design)
            : .custom(spec.typography.fontFamily, size: size, relativeTo: role.textStyle)
        return base
    }

    var lineSpacing: CGFloat {
        spec.typography.baseSize * (spec.typography.lineHeight - 1)
    }

    enum FontRole {
        case body, heading1, heading2, heading3, code, caption

        var scale: Double {
            switch self {
            case .body: 1.0
            case .heading1: 1.75
            case .heading2: 1.4
            case .heading3: 1.15
            case .code: 0.92
            case .caption: 0.82
            }
        }

        var textStyle: Font.TextStyle {
            switch self {
            case .body, .code: .body
            case .heading1: .title
            case .heading2: .title2
            case .heading3: .title3
            case .caption: .caption
            }
        }

        var design: Font.Design { self == .code ? .monospaced : .default }

        func weight(_ headingWeight: Int) -> Font.Weight {
            switch self {
            case .body, .code, .caption: return .regular
            case .heading1, .heading2, .heading3:
                switch headingWeight {
                case ..<300: return .light
                case ..<450: return .regular
                case ..<550: return .medium
                case ..<650: return .semibold
                case ..<800: return .bold
                default:     return .heavy
                }
            }
        }
    }
}

extension UIColor {
    /// Parse `#RRGGBB` / `#RRGGBBAA`. Returns nil rather than a wrong colour so
    /// callers fall back to the default theme.
    convenience init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6 || value.count == 8,
              let raw = UInt64(value, radix: 16) else { return nil }

        let hasAlpha = value.count == 8
        let r = Double((raw >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = Double((raw >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = Double((raw >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? Double(raw & 0xFF) / 255 : 1
        self.init(red: r, green: g, blue: b, alpha: a)
    }
}
