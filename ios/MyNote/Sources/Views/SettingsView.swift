import SwiftUI
import MyNoteCore

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(ThemeManager.self) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var showingPaywall = false
    @State private var editingTheme: ThemeSpec?
    @State private var pendingProvider: StorageProvider?
    @State private var showingEraseConfirmation = false

    var body: some View {
        NavigationStack {
            Form {
                backupSection
                appearanceSection
                if AppFeatures.paidFeaturesEnabled { purchaseSection }
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
            .sheet(item: $editingTheme) { ThemeEditorView(draft: $0) }
            .alert("Move your notes?", isPresented: .constant(pendingProvider != nil)) {
                Button("Cancel", role: .cancel) { pendingProvider = nil }
                Button("Switch", role: .destructive) {
                    if let target = pendingProvider {
                        Task { await connect(target) }
                    }
                    pendingProvider = nil
                }
            } message: {
                // Records carry no account, so mixing two backups would put one
                // person's notes into another's Drive. Saying this plainly beats
                // silently deleting.
                Text("Notes on this device will be removed and replaced with whatever is in \(pendingProvider?.title ?? "the new location"). Anything not already backed up will be lost.")
            }
        }
    }

    // MARK: - Backup

    private var backupSection: some View {
        Section {
            ForEach(StorageProvider.allCases) { option in
                if option != .googleDrive || AppEnvironment.isGoogleDriveConfigured {
                    Button {
                        select(option)
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: option.symbol)
                                .foregroundStyle(theme.current.accentColor)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.title)
                                    .foregroundStyle(theme.current.textPrimary)
                                Text(option.detail)
                                    .font(theme.current.font(.caption))
                                    .foregroundStyle(theme.current.textSecondary)
                            }
                            Spacer()
                            if app.syncCoordinator.provider == option {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            SyncStatusView()

            if app.syncCoordinator.provider != .none {
                Button("Back up now") {
                    Task { await app.syncCoordinator.syncNow() }
                }
                .disabled(app.syncCoordinator.status.isSyncing)
            }
        } header: {
            Text("Backup")
        } footer: {
            Text("MyNote has no servers. Your notes go to storage you already own, and we never see them.")
        }
    }

    private func select(_ option: StorageProvider) {
        guard option != app.syncCoordinator.provider else { return }

        if app.syncCoordinator.provider != .none {
            pendingProvider = option      // switching wipes; confirm first
        } else {
            Task { await connect(option) }
        }
    }

    private func connect(_ option: StorageProvider) async {
        if option == .googleDrive && !app.googleAuth.isSignedIn {
            await app.syncCoordinator.signInToGoogle()
        } else {
            await app.syncCoordinator.select(option)
        }
        app.applyEntitlements()
        app.purchases.applyRemoteLicense(await app.syncCoordinator.readLicense())
        app.applyEntitlements()
        app.loadSyncedThemes()
    }

    // MARK: - Appearance

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
                ThemeRow(spec: spec,
                         isSelected: spec.id == theme.current.spec.id,
                         canEdit: theme.canEdit) {
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
                if theme.canEdit { editingTheme = theme.draftFromCurrent() }
                else { showingPaywall = true }
            } label: {
                Label(theme.canEdit ? "New theme" : "Unlock custom themes",
                      systemImage: theme.canEdit ? "plus" : "lock")
            }
        } header: {
            Text("Theme")
        } footer: {
            if !theme.canEdit {
                Text("The three built-in themes are free. Building your own is part of Pro.")
            }
        }
    }

    // MARK: - Purchase

    private var purchaseSection: some View {
        Section("MyNote Pro") {
            LabeledContent("Status", value: app.purchases.isPro ? "Unlocked" : "Not purchased")
            if !app.purchases.isPro {
                Button("See what's included") { showingPaywall = true }
            }
            Button("Restore purchase") { Task { await app.purchases.restore() } }
            if app.purchases.sawRemoteLicense {
                Text("Unlocked from a purchase found in your backup.")
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
            Button("Erase notes on this device", role: .destructive) {
                showingEraseConfirmation = true
            }
            .confirmationDialog("Erase every note on this iPhone?",
                                isPresented: $showingEraseConfirmation, titleVisibility: .visible) {
                Button("Erase", role: .destructive) {
                    Task { await app.eraseLocalData() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(app.syncCoordinator.provider == .none
                     ? "These notes are not backed up anywhere. This cannot be undone."
                     : "Your backup in \(app.syncCoordinator.provider.title) is untouched.")
            }
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
                    if isSelected { Image(systemName: "checkmark").foregroundStyle(.tint) }
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
