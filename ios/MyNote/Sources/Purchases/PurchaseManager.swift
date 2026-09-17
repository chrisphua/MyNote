import Foundation
import StoreKit
import MyNoteCore

/// StoreKit 2 purchasing.
///
/// One product. With no server to run, MyNote has no recurring cost, so charging
/// a recurring price would be asking for money to cover an expense that does not
/// exist. A single lifetime unlock is the honest shape — and it removes the
/// margin decay that made a lifetime price risky when we were hosting storage.
@Observable
@MainActor
final class PurchaseManager {
    static let proProductId = "io.mynote.pro"
    static let proEntitlement = "pro"

    private(set) var product: Product?
    private(set) var entitlements: Set<String> = []
    private(set) var isPurchasing = false
    private(set) var lastError: String?
    private(set) var loadFailed = false

    /// True once a licence from the cloud folder has been merged in — which is
    /// how a purchase made on Android reaches an iPhone.
    private(set) var sawRemoteLicense = false

    var isPro: Bool { entitlements.contains(Self.proEntitlement) }

    /// Called after a purchase so the licence can be written to the user's
    /// folder for their other devices.
    var onPurchase: (@MainActor (License) -> Void)?

    private final class TaskBox: @unchecked Sendable {
        var task: Task<Void, Never>?
        deinit { task?.cancel() }
    }
    private let updates = TaskBox()

    init() {
        // A transaction can arrive at any time — an Ask to Buy approval, a
        // purchase made on another device, a restore — so we listen for life.
        updates.task = Task { [weak self] in
            for await update in Transaction.updates {
                guard let self else { return }
                if case .verified(let transaction) = update {
                    await self.adopt(transaction)
                    await transaction.finish()
                }
            }
        }
    }

    func loadProducts() async {
        do {
            product = try await Product.products(for: [Self.proProductId]).first
            loadFailed = product == nil
        } catch {
            // Offline, or not yet approved in App Store Connect.
            loadFailed = true
            lastError = "Couldn't load the price. Check your connection."
        }
    }

    func purchase() async -> Bool {
        guard let product else { return false }
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
                await adopt(transaction)
                await transaction.finish()
                return true

            case .userCancelled:
                return false

            case .pending:
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

    /// What StoreKit believes this device owns, independent of any folder.
    func refreshLocalEntitlements() async {
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            await adopt(transaction, announce: false)
        }
    }

    /// Adopt a licence found in the user's cloud folder.
    ///
    /// Union with what StoreKit says, never a replacement: a purchase made on
    /// Android exists only in the file, and one made here may not be uploaded
    /// yet. Neither may revoke the other.
    func applyRemoteLicense(_ license: License?) {
        guard let license else { return }
        entitlements = License.combine(local: entitlements, remote: license)
        sawRemoteLicense = true
    }

    private func adopt(_ transaction: Transaction, announce: Bool = true) async {
        guard transaction.productID == Self.proProductId else { return }
        guard transaction.revocationDate == nil else {
            // Refunded or charged back.
            entitlements.remove(Self.proEntitlement)
            return
        }

        entitlements.insert(Self.proEntitlement)

        if announce {
            onPurchase?(License(
                entitlements: [Self.proEntitlement],
                productId: transaction.productID,
                platform: "apple",
                purchasedAt: Int64(transaction.purchaseDate.timeIntervalSince1970 * 1000),
                receipt: String(transaction.id)
            ))
        }
    }
}
