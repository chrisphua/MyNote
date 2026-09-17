import SwiftUI
import StoreKit
import MyNoteCore

/// The paywall.
///
/// One product, one price, paid once. There is no server behind MyNote, so there
/// is no recurring cost to cover and no honest case for a recurring charge.
struct PaywallView: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(ThemeManager.self) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var isRestoring = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    card
                    ownershipNote
                    footer
                }
                .padding(20)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .background(theme.current.background)
            .navigationTitle("MyNote Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now") { dismiss() }
                }
            }
            .task { await app.purchases.loadProducts() }
            .onChange(of: app.purchases.isPro) { _, isPro in
                if isPro { dismiss() }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MyNote is free to write in.")
                .font(theme.current.font(.heading2))
                .foregroundStyle(theme.current.textPrimary)
            Text("Unlimited notes, every block type and three themes cost nothing, forever. Pro adds the two things people ask for most.")
                .font(theme.current.font(.body))
                .foregroundStyle(theme.current.textSecondary)
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("MyNote Pro")
                        .font(theme.current.font(.heading3))
                        .foregroundStyle(theme.current.textPrimary)
                    Text("One payment. Yours for good.")
                        .font(theme.current.font(.caption))
                        .foregroundStyle(theme.current.textSecondary)
                }
                Spacer()
                Text(app.purchases.product?.displayPrice ?? "—")
                    .font(theme.current.font(.heading3))
                    .foregroundStyle(theme.current.textPrimary)
                    .monospacedDigit()
            }

            ForEach([
                "Design your own themes — colours for light and dark, fonts, spacing, corners",
                "Back up to your own iCloud Drive or Google Drive",
                "Keep every device in step, automatically",
                "Your notes stay in storage you control. We host nothing.",
            ], id: \.self) { bullet in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "checkmark")
                        .font(.caption)
                        .foregroundStyle(theme.current.accentColor)
                    Text(bullet)
                        .font(theme.current.font(.body))
                        .foregroundStyle(theme.current.textSecondary)
                }
            }

            Button {
                Task { await app.purchases.purchase() }
            } label: {
                Text(app.purchases.isPro ? "Already yours" : "Unlock Pro")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(app.purchases.product == nil || app.purchases.isPro || app.purchases.isPurchasing)

            if app.purchases.loadFailed {
                Text("Couldn't load the price. Check your connection.")
                    .font(theme.current.font(.caption))
                    .foregroundStyle(theme.current.textSecondary)
            }
        }
        .padding(16)
        .background(theme.current.surface)
        .clipShape(RoundedRectangle(cornerRadius: theme.current.cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: theme.current.cornerRadius)
                .stroke(theme.current.accentColor, lineWidth: 2)
        }
    }

    private var ownershipNote: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "lock.icloud")
                .foregroundStyle(theme.current.accentColor)
            Text("Buy on either platform. If you back up to Google Drive, connecting the same account on Android unlocks Pro there too — the receipt travels with your notes.")
                .font(theme.current.font(.caption))
                .foregroundStyle(theme.current.textSecondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.current.surface.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: theme.current.cornerRadius))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = app.purchases.lastError {
                Text(error)
                    .font(theme.current.font(.caption))
                    .foregroundStyle(.red)
            }

            Button {
                isRestoring = true
                Task {
                    await app.purchases.restore()
                    isRestoring = false
                }
            } label: {
                if isRestoring { ProgressView() } else { Text("Restore purchase") }
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.current.accentColor)

            HStack(spacing: 16) {
                Link("Terms", destination: URL(string: "https://mynote.io/terms")!)
                Link("Privacy", destination: URL(string: "https://mynote.io/privacy")!)
            }
            .font(theme.current.font(.caption))
        }
    }
}
