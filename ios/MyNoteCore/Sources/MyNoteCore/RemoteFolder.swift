import Foundation

/// A folder in storage the user already owns and pays for.
///
/// MyNote has no server. Notes are backed up into the user's own Google Drive or
/// iCloud Drive, which is why there is no hosting bill, no account to create with
/// us, and nothing of theirs sitting on hardware we control.
///
/// Implementations are thin: list, read, write, delete. Everything about merging
/// and conflict resolution lives above this, so adding another provider later is
/// four methods and no new sync logic.
public protocol RemoteFolder: Sendable {
    /// Human-readable name for the UI ("Google Drive", "iCloud Drive").
    var displayName: String { get }

    /// Files directly inside the MyNote folder.
    func list() async throws -> [RemoteFile]

    func read(_ name: String) async throws -> Data
    func write(_ name: String, data: Data) async throws
    func delete(_ name: String) async throws
}

public struct RemoteFile: Sendable, Equatable {
    public let name: String
    public let modifiedAt: Date
    public let size: Int
    /// Provider's change marker — an etag, a revision id, a content hash.
    ///
    /// Used to skip downloading a device file that has not changed since the
    /// last merge. Without it every sync would pull every other device's whole
    /// file, which on a metered connection is the difference between a usable
    /// app and an uninstall.
    public let version: String

    public init(name: String, modifiedAt: Date, size: Int, version: String) {
        self.name = name
        self.modifiedAt = modifiedAt
        self.size = size
        self.version = version
    }
}

public enum RemoteFolderError: Error, Equatable, Sendable {
    /// The user has not connected a storage provider yet.
    case notConnected
    /// Signed out, token expired, or access revoked in the provider's settings.
    case needsReauthentication
    case notFound(String)
    /// The user's Drive or iCloud is full. Their storage, their quota.
    case storageFull
    case offline
    case provider(String)
}

// MARK: - The file format

/// One device's contribution to the shared folder.
///
/// Each device writes exactly one of these and never touches another's, which is
/// what makes concurrent edits safe without any locking: there is no file two
/// devices can both write, so there is no write conflict to resolve. Merging
/// happens on read, by hybrid logical clock, exactly as it did against a server.
public struct DeviceFile: Codable, Sendable {
    public static let currentFormat = 1

    public var format: Int
    public var deviceId: String
    public var updatedAt: Int64
    /// Every record whose newest known version was authored by this device.
    public var changes: [Change]

    public init(deviceId: String, updatedAt: Int64, changes: [Change]) {
        self.format = Self.currentFormat
        self.deviceId = deviceId
        self.updatedAt = updatedAt
        self.changes = changes
    }

    /// `device-<id>.json`. The device id is also the HLC node, so a record's
    /// clock already says which file it belongs in.
    public static func fileName(for deviceId: String) -> String {
        "device-\(deviceId).json"
    }

    public static func deviceId(fromFileName name: String) -> String? {
        guard name.hasPrefix("device-"), name.hasSuffix(".json") else { return nil }
        return String(name.dropFirst("device-".count).dropLast(".json".count))
    }

    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public static func decode(_ data: Data) throws -> DeviceFile {
        let file = try JSONDecoder().decode(DeviceFile.self, from: data)
        // A newer app may add fields; refusing to read the file would strand a
        // user whose other phone updated first. Unknown fields are simply
        // ignored by Codable, so only a genuinely newer *format* is a problem.
        guard file.format <= currentFormat else {
            throw RemoteFolderError.provider(
                "This backup was written by a newer version of MyNote. Update the app to read it."
            )
        }
        return file
    }
}
