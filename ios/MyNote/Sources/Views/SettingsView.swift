import SwiftUI
import MyNoteCore

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(ThemeManager.self) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var showingPaywall = false
    @State private var showingThemeEditor = false
    @State private var editingTheme: ThemeSpec?

    var body: some View {
        NavigationStack {
            Form {
                accountSection
                appearanceSection
                syncSection
                purchasesSection
                aboutSection
            }
            .scrollContentBackground(.hidden)
            .background(theme.current.background)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showingPaywall) { PaywallView() }
            .sheet(item: $editingTheme) { spec in
                ThemeEditorView(draft: spec)
            }
        }
    }

    // MARK: - Sections

    private var accountSection: some View {
        Section("Account") {
            switch app.auth.status {
            case .signedIn(_, let email):
                LabeledContent("Signed in", value: email ?? "Apple ID")
                Button("Sign out", role: .destructive) { app.auth.signOut() }
            case .signedOut:
                NavigationLink("Sign in") { SignInView() }
                Text("Your notes are saved on this device. Sign in to sync them and to carry purchases to another device.")
                    .font(theme.current.font(.caption))
                    .foregroundStyle(theme.current.textSecondary)
            case .unconfigured:
                Text("This build has no sign-in credentials, so MyNote is running local-only.")
                    .font(theme.current.font(.caption))
                    .foregroundStyle(theme.current.textSecondary)
            }
        }
    }

    private var appearanceSection: some View {
        Section {
            Picker("Appearance", selection: Binding(
                get: { theme.appearance },
                set: { theme.appearance = $0 }
            )) {
                ForEach(ThemeManager.Appearance.allCases) { option in
                    Text(option.label).tag(option)
                }
            }

            ForEach(theme.allThemes, id: \.id) { spec in
                ThemeRow(
                    spec: spec,
                    isSelected: spec.id == theme.current.spec.id,
                    canEdit: theme.canEdit
                ) {
                    theme.select(spec)
                } onEdit: {
                    // The gate is here, not inside the editor, so the paywall
                    // appears before the user invests effort in a design.
                    if theme.canEdit {
                        editingTheme = spec.isPreset ? theme.draftFromCurrent() : spec
                    } else {
                        showingPaywall = true
                    }
                }
            }

            Button {
                if theme.canEdit {
                    editingTheme = theme.draftFromCurrent()
                } else {
                    showingPaywall = true
                }
            } label: {
                Label(theme.canEdit ? "New theme" : "Unlock custom themes", systemImage: theme.canEdit ? "plus" : "lock")
            }
        } header: {
            Text("Theme")
        } footer: {
            if !theme.canEdit {
                Text("The three built-in themes are free. Custom themes — your own colours, fonts, spacing and corners — are a one-time purchase.")
            }
        }
    }

    private var syncSection: some View {
        Section("Sync") {
            SyncStatusView()
            if app.purchases.canSync {
                Button("Sync now") { Task { await app.syncCoordinator.syncNow() } }
                    .disabled(app.syncCoordinator.status.isSyncing)
            } else {
                Button("Turn on cloud sync") { showingPaywall = true }
            }
        }
    }

    private var purchasesSection: some View {
        Section("Purchases") {
            LabeledContent("Custom themes",
                           value: app.purchases.canCustomizeThemes ? "Unlocked" : "Locked")
            LabeledContent("Cloud sync",
                           value: app.purchases.canSync ? "Active" : "Not active")
            Button("Restore purchases") { Task { await app.purchases.restore() } }
            if !app.purchases.serverConfirmed && app.auth.isSignedIn {
                Text("Purchases made on another platform appear once you're online.")
                    .font(theme.current.font(.caption))
                    .foregroundStyle(theme.current.textSecondary)
            }
        }
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: Bundle.main.appVersion)
            Link("Privacy policy", destination: URL(string: "https://mynote.io/privacy")!)
            Link("Terms of use", destination: URL(string: "https://mynote.io/terms")!)
        }
    }
}

private struct ThemeRow: View {
    let spec: ThemeSpec
    let isSelected: Bool
    let canEdit: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void

    var body: some View {
        HStack {
            Button(action: onSelect) {
                HStack(spacing: 10) {
                    ThemeSwatch(spec: spec)
                    Text(spec.name)
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark").foregroundStyle(.tint)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onEdit) {
                Image(systemName: spec.isPreset ? "square.on.square" : "slider.horizontal.3")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(spec.isPreset ? "Duplicate \(spec.name)" : "Edit \(spec.name)")
        }
    }
}

struct ThemeSwatch: View {
    let spec: ThemeSpec
    var size: CGFloat = 22

    var body: some View {
        // Shows the theme's own colours, so the list is a preview rather than
        // a set of names.
        ZStack {
            Circle().fill(Color(hexOrClear: spec.light.background))
            Circle()
                .trim(from: 0.5, to: 1)
                .fill(Color(hexOrClear: spec.dark.background))
                .rotationEffect(.degrees(-90))
            Circle()
                .fill(Color(hexOrClear: spec.light.accent))
                .frame(width: size * 0.38, height: size * 0.38)
        }
        .frame(width: size, height: size)
        .overlay(Circle().stroke(Color(hexOrClear: spec.light.border), lineWidth: 1))
    }
}

extension Color {
    init(hexOrClear hex: String) {
        self = UIColor(hex: hex).map(Color.init) ?? .clear
    }
}

extension Bundle {
    var appVersion: String {
        let short = object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(short) (\(build))"
    }
}

extension ThemeSpec: @retroactive Identifiable {}
