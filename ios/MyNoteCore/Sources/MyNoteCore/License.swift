import Foundation

/// Proof of purchase, carried in the user's own cloud folder.
///
/// With no server there is nowhere neutral to record that someone paid, so the
/// receipt rides along with the notes. Buy on an Android phone, connect the same
/// Google Drive on an iPhone, and Pro is already unlocked.
///
/// **Threat model, stated plainly.** The store's own receipt is the strong
/// proof, and each platform verifies its own: StoreKit on iOS, Play's signature
/// on Android. This file is the weaker, cross-platform path — it lives in
/// storage the user controls, so a determined person could forge it. That buys
/// them a one-time purchase they could have made for the price of a sandwich,
/// and the alternative is running a server purely to police it. Not worth it.
public struct License: Codable, Equatable, Sendable {
    public static let fileName = "license.json"
    public static let currentFormat = 1

    public var format: Int
    /// Entitlement ids, e.g. `["pro"]`. A list so a future split into separate
    /// products does not need a new file format.
    public var entitlements: [String]
    public var productId: String
    /// Which store the purchase was made in — for support, not for gating.
    public var platform: String
    public var purchasedAt: Int64
    /// The store's own receipt, kept verbatim for support and disputes.
    public var receipt: String?

    public init(entitlements: [String], productId: String, platform: String,
                purchasedAt: Int64, receipt: String? = nil) {
        self.format = Self.currentFormat
        self.entitlements = entitlements
        self.productId = productId
        self.platform = platform
        self.purchasedAt = purchasedAt
        self.receipt = receipt
    }

    public func encoded() throws -> Data { try JSONEncoder().encode(self) }

    public static func decode(_ data: Data) -> License? {
        guard let license = try? JSONDecoder().decode(License.self, from: data),
              license.format <= currentFormat else { return nil }
        return license
    }
}

public extension License {
    /// Merge what the folder says with what this device's store says.
    ///
    /// Union, never intersection: a purchase made on the other platform exists
    /// only in the file, and a purchase made here may not have been uploaded
    /// yet. Taking the union means neither can revoke the other.
    static func combine(local: Set<String>, remote: License?) -> Set<String> {
        local.union(remote?.entitlements ?? [])
    }
}
