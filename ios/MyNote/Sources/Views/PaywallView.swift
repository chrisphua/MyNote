import SwiftUI
import StoreKit
import MyNoteCore

/// The paywall.
///
/// Two separate things are on sale, and the copy says so plainly: a one-time
/// unlock for themes, and a subscription for sync. Bundling them would force
/// people who only want their own colours into a recurring charge.
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

                    if app.purchases.loadFailed {
                        unavailableNotice
                    } else {
                        purchaseCard(
                            id: .themesLifetime,
                            title: "Custom themes",
                            subtitle: "One payment, yours for good",
                            bullets: [
                                "Design your own colour palettes for light and dark",
                                "Choose fonts, text size and line height",
                                "Tune spacing, corners and page width",
                                "Unlimited saved themes",
                            ]
                        )

                        purchaseCard(
                            id: .syncYearly,
                            title: "Cloud sync — yearly",
                            subtitle: "Best value",
                            bullets: [
                                "Your notes on every device you sign in to",
                                "iPhone, iPad and Android share one account",
                                "1 GB for images and attachments",
                                "Keeps working offline; syncs when you're back",
                            ],
                            highlighted: true
                        )

                        purchaseCard(
                            id: .syncMonthly,
                            title: "Cloud sync — monthly",
                            subtitle: "Cancel any time",
                            bullets: []
                        )
                    }

                    crossPlatformNote
                    footer
                }
                .padding(20)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .background(theme.current.background)
            .navigationTitle("Upgrade")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now") { dismiss() }
                }
            }
            .task { await app.purchases.loadProducts() }
            .onChange(of: app.purchases.entitlements) { _, new in
                // Dismiss as soon as the thing they came for is unlocked.
                if !new.isEmpty { dismiss() }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MyNote is free to write in.")
                .font(theme.current.font(.heading2))
                .foregroundStyle(theme.current.textPrimary)
            Text("Unlimited notes, every block type and three themes cost nothing, forever. These two add-ons are what keep it that way.")
                .font(theme.current.font(.body))
                .foregroundStyle(theme.current.textSecondary)
        }
    }

    private func purchaseCard(
        id: PurchaseManager.ProductID,
        title: String,
        subtitle: String,
        bullets: [String],
        highlighted: Bool = false
    ) -> some View {
        let product = app.purchases.product(id)
        let owned = app.purchases.entitlements.contains(
            PurchaseManager.entitlement(for: id.rawValue) ?? ""
        )

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(theme.current.font(.heading3))
                        .foregroundStyle(theme.current.textPrimary)
                    Text(subtitle)
                        .font(theme.current.font(.caption))
                        .foregroundStyle(theme.current.textSecondary)
                }
                Spacer()
                Text(product?.displayPrice ?? "—")
                    .font(theme.current.font(.heading3))
                    .foregroundStyle(theme.current.textPrimary)
                    .monospacedDigit()
            }

            ForEach(bullets, id: \.self) { bullet in
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
                guard let product else { return }
                Task { await app.purchases.purchase(product) }
            } label: {
                Text(owned ? "Already yours" : "Continue")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(product == nil || owned || app.purchases.isPurchasing)
        }
        .padding(16)
        .background(theme.current.surface)
        .clipShape(RoundedRectangle(cornerRadius: theme.current.cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: theme.current.cornerRadius)
                .stroke(highlighted ? theme.current.accentColor : theme.current.border,
                        lineWidth: highlighted ? 2 : 1)
        }
    }

    private var crossPlatformNote: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "iphone.and.arrow.forward")
                .foregroundStyle(theme.current.accentColor)
            Text("Buy once, on either platform. Sign in with the same account on Android and it's already unlocked.")
                .font(theme.current.font(.caption))
                .foregroundStyle(theme.current.textSecondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.current.surface.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: theme.current.cornerRadius))
    }

    private var unavailableNotice: some View {
        Text("Prices couldn't be loaded. Check your connection and try again.")
            .font(theme.current.font(.body))
            .foregroundStyle(theme.current.textSecondary)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.current.surface)
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
                if isRestoring { ProgressView() } else { Text("Restore purchases") }
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.current.accentColor)

            // Apple requires subscription terms to be visible at the point of sale.
            Text("Subscriptions renew automatically until cancelled. Manage or cancel in Settings › Apple ID › Subscriptions at least 24 hours before the period ends.")
                .font(theme.current.font(.caption))
                .foregroundStyle(theme.current.textSecondary)

            HStack(spacing: 16) {
                Link("Terms", destination: URL(string: "https://mynote.io/terms")!)
                Link("Privacy", destination: URL(string: "https://mynote.io/privacy")!)
            }
            .font(theme.current.font(.caption))
        }
    }
}
