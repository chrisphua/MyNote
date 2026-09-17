import Foundation

/// A complete visual theme, stored as JSON so it round-trips through sync and
/// stays identical between iOS and Android. Every value a user can change lives
/// here — this type *is* the paid feature.
public struct ThemeSpec: Codable, Equatable, Sendable {
    public struct Palette: Codable, Equatable, Sendable {
        public var background: String
        public var surface: String
        public var textPrimary: String
        public var textSecondary: String
        public var accent: String
        public var border: String
        public var codeBackground: String

        public init(background: String, surface: String, textPrimary: String,
                    textSecondary: String, accent: String, border: String,
                    codeBackground: String) {
            self.background = background
            self.surface = surface
            self.textPrimary = textPrimary
            self.textSecondary = textSecondary
            self.accent = accent
            self.border = border
            self.codeBackground = codeBackground
        }
    }

    public struct Typography: Codable, Equatable, Sendable {
        public var fontFamily: String        // "system" or a bundled family name
        public var baseSize: Double          // points for body text
        public var lineHeight: Double        // multiplier
        public var headingWeight: Int        // 100...900

        public init(fontFamily: String = "system", baseSize: Double = 17,
                    lineHeight: Double = 1.45, headingWeight: Int = 700) {
            self.fontFamily = fontFamily
            self.baseSize = baseSize
            self.lineHeight = lineHeight
            self.headingWeight = headingWeight
        }
    }

    public struct Layout: Codable, Equatable, Sendable {
        public var cornerRadius: Double
        public var contentPadding: Double
        public var blockSpacing: Double
        /// Caps line length on iPad and large phones so text stays readable.
        public var maxContentWidth: Double

        public init(cornerRadius: Double = 10, contentPadding: Double = 16,
                    blockSpacing: Double = 6, maxContentWidth: Double = 720) {
            self.cornerRadius = cornerRadius
            self.contentPadding = contentPadding
            self.blockSpacing = blockSpacing
            self.maxContentWidth = maxContentWidth
        }
    }

    public var id: String
    public var name: String
    public var light: Palette
    public var dark: Palette
    public var typography: Typography
    public var layout: Layout
    /// Presets ship with the app and cannot be edited or deleted.
    public var isPreset: Bool

    public init(id: String = UUID().uuidString, name: String, light: Palette, dark: Palette,
                typography: Typography = Typography(), layout: Layout = Layout(),
                isPreset: Bool = false) {
        self.id = id
        self.name = name
        self.light = light
        self.dark = dark
        self.typography = typography
        self.layout = layout
        self.isPreset = isPreset
    }

    public func encoded() -> String {
        guard let data = try? JSONEncoder().encode(self),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    /// Clamp a user-built theme into renderable ranges.
    ///
    /// A custom theme is arbitrary user input that may also arrive from another
    /// device, so it is validated before it can reach the renderer — an invalid
    /// colour or a 0.1pt font must not be able to make the app unusable.
    public func sanitized() -> ThemeSpec {
        var copy = self
        copy.light = copy.light.sanitized(fallback: ThemeSpec.defaultTheme.light)
        copy.dark = copy.dark.sanitized(fallback: ThemeSpec.defaultTheme.dark)
        copy.typography.baseSize = copy.typography.baseSize.clamped(to: 11...28)
        copy.typography.lineHeight = copy.typography.lineHeight.clamped(to: 1.0...2.5)
        copy.typography.headingWeight = min(max(copy.typography.headingWeight, 100), 900)
        copy.layout.cornerRadius = copy.layout.cornerRadius.clamped(to: 0...32)
        copy.layout.contentPadding = copy.layout.contentPadding.clamped(to: 0...48)
        copy.layout.blockSpacing = copy.layout.blockSpacing.clamped(to: 0...32)
        copy.layout.maxContentWidth = copy.layout.maxContentWidth.clamped(to: 320...1400)
        copy.name = String(copy.name.prefix(60))
        return copy
    }

    public static func decode(_ raw: String) -> ThemeSpec? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ThemeSpec.self, from: data)
    }
}

public extension ThemeSpec {
    /// Free presets. A user who never pays still gets a genuinely good-looking
    /// app; what they are buying is the ability to build their own.
    static let presets: [ThemeSpec] = [defaultTheme, sepia, midnight]

    static let defaultTheme = ThemeSpec(
        id: "preset.default",
        name: "MyNote",
        light: Palette(background: "#FFFFFF", surface: "#F7F7F5", textPrimary: "#1A1A18",
                       textSecondary: "#6B6B66", accent: "#2F6FED", border: "#E4E4E0",
                       codeBackground: "#F2F2EF"),
        dark: Palette(background: "#191919", surface: "#222222", textPrimary: "#EDEDEC",
                      textSecondary: "#9B9B96", accent: "#6C9BFF", border: "#2E2E2E",
                      codeBackground: "#242424"),
        isPreset: true
    )

    static let sepia = ThemeSpec(
        id: "preset.sepia",
        name: "Sepia",
        light: Palette(background: "#FBF3E4", surface: "#F3E8D2", textPrimary: "#3B2F22",
                       textSecondary: "#7A6A54", accent: "#A8601F", border: "#E2D3B8",
                       codeBackground: "#F0E4CC"),
        dark: Palette(background: "#241E16", surface: "#2E261C", textPrimary: "#EDE0CB",
                      textSecondary: "#A7997E", accent: "#D89A4E", border: "#3B3125",
                      codeBackground: "#2A2219"),
        isPreset: true
    )

    static let midnight = ThemeSpec(
        id: "preset.midnight",
        name: "Midnight",
        light: Palette(background: "#EEF1F8", surface: "#E2E7F3", textPrimary: "#161B2B",
                       textSecondary: "#5A6480", accent: "#4A5CF0", border: "#CDD5E8",
                       codeBackground: "#E6EAF5"),
        dark: Palette(background: "#0E1119", surface: "#161A26", textPrimary: "#E5E9F5",
                      textSecondary: "#8D97B2", accent: "#7B8BFF", border: "#222838",
                      codeBackground: "#141824"),
        isPreset: true
    )
}


// MARK: - Validation

extension ThemeSpec.Palette {
    /// Replace any value that is not a `#RRGGBB` / `#RRGGBBAA` colour.
    func sanitized(fallback: ThemeSpec.Palette) -> ThemeSpec.Palette {
        ThemeSpec.Palette(
            background: ThemeSpec.validHex(background) ?? fallback.background,
            surface: ThemeSpec.validHex(surface) ?? fallback.surface,
            textPrimary: ThemeSpec.validHex(textPrimary) ?? fallback.textPrimary,
            textSecondary: ThemeSpec.validHex(textSecondary) ?? fallback.textSecondary,
            accent: ThemeSpec.validHex(accent) ?? fallback.accent,
            border: ThemeSpec.validHex(border) ?? fallback.border,
            codeBackground: ThemeSpec.validHex(codeBackground) ?? fallback.codeBackground
        )
    }
}

public extension ThemeSpec {
    static func validHex(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces).uppercased()
        guard t.hasPrefix("#") else { return nil }
        let body = t.dropFirst()
        guard body.count == 6 || body.count == 8,
              body.allSatisfy({ $0.isHexDigit })
        else { return nil }
        return "#" + body
    }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
