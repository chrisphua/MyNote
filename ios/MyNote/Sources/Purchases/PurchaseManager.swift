import Foundation
import StoreKit
import MyNoteCore

/// StoreKit 2 purchasing.
///
/// StoreKit is the source of truth for *making* a purchase; our Worker is the
/// source of truth for *owning* one. That split is what lets an iOS purchase
/// unlock the feature on Android: we hand Apple's transaction id to the server,
/// which records the entitlement against the Firebase uid rather than the device.
@Observable
@MainActor
final class PurchaseManager {
    enum ProductID: String, CaseIterable {
        case themesLifetime = "io.mynote.themes.lifetime"
        case syncMonthly    = "io.mynote.sync.monthly"
        case syncYearly     = "io.mynote.sync.yearly"
    }

    private(set) var products: [Product] = []
    private(set) var entitlements: Set<String> = []
    private(set) var isPurchasing = false
    private(set) var lastError: String?
    private(set) var loadFailed = false

    /// Set once the server confirms; until then we trust StoreKit locally so a
    /// purchase feels instant even before the round trip completes.
    private(set) var serverConfirmed = false

    var canCustomizeThemes: Bool { entitlements.contains("theme_pro") }
    var canSync: Bool { entitlements.contains("cloud_sync") }

    /// Holds the transaction listener.
    ///
    /// `deinit` is nonisolated and so cannot touch main-actor state, which is
    /// why the task lives in a box that cancels itself when this object goes
    /// away rather than in a property we cancel by hand.
    private final class TaskBox: @unchecked Sendable {
        var task: Task<Void, Never>?
        deinit { task?.cancel() }
    }

    private let updates = TaskBox()
    private var verifyWithServer: (@Sendable (String) async throws -> [Entitlement])?

    init() {
        // A transaction can arrive at any time — an Ask to Buy approval, a
        // renewal, a purchase made on another device — so we listen for life.
        updates.task = Task { [weak self] in
            for await update in Transaction.updates {
                guard let self else { return }
                if case .verified(let transaction) = update {
                    await self.handle(transaction)
                    await transaction.finish()
                }
            }
        }
    }

    func configure(verifier: @escaping @Sendable (String) async throws -> [Entitlement]) {
        verifyWithServer = verifier
    }

    func loadProducts() async {
        do {
            products = try await Product.products(for: ProductID.allCases.map(\.rawValue))
                .sorted { $0.price < $1.price }
            loadFailed = false
        } catch {
            // Offline, or products not yet approved in App Store Connect.
            loadFailed = true
            lastError = "Couldn't load prices. Check your connection."
        }
    }

    func product(_ id: ProductID) -> Product? {
        products.first { $0.id == id.rawValue }
    }

    func purchase(_ product: Product) async -> Bool {
        isPurchasing = true
        lastError = nil
        defer { isPurchasing = false }

        do {
            switch try await product.purchase() {
            case .success(let verification):
                guard case .verified(let transaction) = verification else {
                    // StoreKit could not verify its own signature: treat as fraud.
                    lastError = "That purchase couldn't be verified."
                    return false
                }
                await handle(transaction)
                await transaction.finish()
                return true

            case .userCancelled:
                return false

            case .pending:
                // Ask to Buy, or a payment method needing approval.
                lastError = "Your purchase is waiting for approval. We'll unlock it automatically."
                return false

            @unknown default:
                return false
            }
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Re-read what this Apple ID owns. Apple requires a visible Restore control.
    func restore() async {
        isPurchasing = true
        defer { isPurchasing = false }
        try? await AppStore.sync()
        await refreshLocalEntitlements()
    }

    /// What StoreKit believes this device owns, independent of our server.
    func refreshLocalEntitlements() async {
        var found: Set<String> = []
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            if let entitlement = Self.entitlement(for: transaction.productID) {
                found.insert(entitlement)
            }
            // Push anything the server may not know about yet.
            await handle(transaction, updateLocal: false)
        }
        // Union rather than replace: an entitlement bought on Android lives only
        // on the server, and StoreKit has never heard of it.
        entitlements.formUnion(found)
    }

    /// Adopt the server's answer, which is authoritative across platforms.
    func applyServerEntitlements(_ list: [Entitlement]) {
        entitlements = Set(list.filter(\.active).map(\.entitlement))
        serverConfirmed = true
    }

    private func handle(_ transaction: Transaction, updateLocal: Bool = true) async {
        if updateLocal, let entitlement = Self.entitlement(for: transaction.productID) {
            entitlements.insert(entitlement)
        }
        guard let verifyWithServer else { return }
        do {
            let list = try await verifyWithServer(String(transaction.id))
            applyServerEntitlements(list)
        } catch {
            // The server will catch up from Apple's server notification, and the
            // next launch retries. Never block the user on our own backend.
            lastError = nil
        }
    }

    static func entitlement(for productID: String) -> String? {
        switch ProductID(rawValue: productID) {
        case .themesLifetime: return "theme_pro"
        case .syncMonthly, .syncYearly: return "cloud_sync"
        case .none: return nil
        }
    }
}
