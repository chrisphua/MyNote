import SwiftUI
import MyNoteCore

/// The paid feature itself: a live editor for every value in a `ThemeSpec`.
///
/// Edits preview instantly against real content, because picking colours against
/// a blank swatch tells you nothing about how a page will actually read.
struct ThemeEditorView: View {
    @State var draft: ThemeSpec

    @Environment(AppEnvironment.self) private var app
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var editingDark = false

    private var preview: Theme { Theme(spec: draft) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Theme name", text: $draft.name)
                }

                Section {
                    LivePreview(theme: preview, dark: editingDark)
                        .listRowInsets(EdgeInsets())
                } header: {
                    HStack {
                        Text("Preview")
                        Spacer()
                        Picker("", selection: $editingDark) {
                            Text("Light").tag(false)
                            Text("Dark").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 160)
                    }
                }

                Section(editingDark ? "Dark colours" : "Light colours") {
                    colorRow("Background", \.background)
                    colorRow("Surface", \.surface)
                    colorRow("Text", \.textPrimary)
                    colorRow("Secondary text", \.textSecondary)
                    colorRow("Accent", \.accent)
                    colorRow("Border", \.border)
                    colorRow("Code background", \.codeBackground)
                }

                Section("Typography") {
                    slider("Text size", value: $draft.typography.baseSize, range: 11...28, unit: "pt")
                    slider("Line height", value: $draft.typography.lineHeight, range: 1.0...2.5, format: "%.2f")
                    Stepper(
                        "Heading weight: \(draft.typography.headingWeight)",
                        value: $draft.typography.headingWeight, in: 100...900, step: 100
                    )
                }

                Section("Layout") {
                    slider("Corner radius", value: $draft.layout.cornerRadius, range: 0...32, unit: "pt")
                    slider("Page padding", value: $draft.layout.contentPadding, range: 0...48, unit: "pt")
                    slider("Block spacing", value: $draft.layout.blockSpacing, range: 0...32, unit: "pt")
                    slider("Max page width", value: $draft.layout.maxContentWidth, range: 320...1400, unit: "pt")
                }

                if !draft.isPreset && themeManager.customThemes.contains(where: { $0.id == draft.id }) {
                    Section {
                        Button("Delete theme", role: .destructive) {
                            themeManager.deleteCustom(draft)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("Edit theme")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func save() {
        guard let saved = themeManager.saveCustom(draft) else { return }
        themeManager.select(saved)
        // Themes sync too, so a theme built on the phone shows up on the tablet.
        Task {
            await NoteRepository(store: app.store, coordinator: app.syncCoordinator)
                .saveTheme(saved)
        }
        dismiss()
    }

    private func colorRow(_ label: String, _ key: WritableKeyPath<ThemeSpec.Palette, String>) -> some View {
        let binding = Binding<Color>(
            get: {
                let hex = editingDark ? draft.dark[keyPath: key] : draft.light[keyPath: key]
                return Color(hexOrClear: hex)
            },
            set: { newColor in
                let hex = newColor.hexString
                if editingDark { draft.dark[keyPath: key] = hex }
                else { draft.light[keyPath: key] = hex }
            }
        )
        return ColorPicker(label, selection: binding, supportsOpacity: false)
    }

    private func slider(_ label: String, value: Binding<Double>,
                        range: ClosedRange<Double>, unit: String = "", format: String = "%.0f") -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                Spacer()
                Text(String(format: format, value.wrappedValue) + unit)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range)
        }
    }
}

/// Renders real blocks, not colour chips, so the effect of a change is honest.
private struct LivePreview: View {
    let theme: Theme
    let dark: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: theme.blockSpacing) {
            Text("Weekend plans")
                .font(theme.font(.heading1))
                .foregroundStyle(theme.textPrimary)
            Text("Body text sits at the size and line height you picked, so you can judge a long paragraph rather than a single word.")
                .font(theme.font(.body))
                .foregroundStyle(theme.textPrimary)
                .lineSpacing(theme.lineSpacing)
            HStack(spacing: 8) {
                Image(systemName: "checkmark.square.fill").foregroundStyle(theme.accentColor)
                Text("A finished to-do").font(theme.font(.body)).foregroundStyle(theme.textPrimary)
            }
            Text("let greeting = \"hello\"")
                .font(theme.font(.code))
                .foregroundStyle(theme.textPrimary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.codeBackground)
                .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
            Text("Secondary text, for dates and captions.")
                .font(theme.font(.caption))
                .foregroundStyle(theme.textSecondary)
        }
        .padding(theme.contentPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.background)
        .environment(\.colorScheme, dark ? .dark : .light)
    }
}

extension Color {
    /// `#RRGGBB` for persistence. Resolved in sRGB so the stored value matches
    /// what the picker showed.
    var hexString: String {
        let resolved = UIColor(self).cgColor
        guard let components = resolved.components, components.count >= 3 else { return "#000000" }
        let r = Int((components[0] * 255).rounded())
        let g = Int((components[1] * 255).rounded())
        let b = Int((components[2] * 255).rounded())
        return String(format: "#%02X%02X%02X", max(0, min(255, r)), max(0, min(255, g)), max(0, min(255, b)))
    }
}
