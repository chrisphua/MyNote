import Foundation

/// What the sync engine needs from local persistence.
///
/// The local database is the source of truth. The file in the user's cloud folder
/// is a *projection* of it, rewritten whenever local records change — so a failed
/// upload can never lose an edit, it only delays one. That is a stronger property
/// than the outbox this replaced, and it is why there is no queue here any more.
public protocol LocalStore: Sendable {
    /// Every record whose newest known version was authored by `node`.
    ///
    /// A record's HLC carries the device that wrote it, so this is just a filter
    /// on the clock — no separate authorship column. When another device takes
    /// over a record, it drops out of ours automatically.
    func changesAuthored(by node: String) async throws -> [Change]

    /// Record a local edit. Returns immediately; upload happens later.
    func recordLocal(_ change: Change) async throws

    /// The clock on our copy of a record, or nil if we have never seen it.
    func currentHlc(_ entity: Entity, _ id: String) async throws -> String?

    /// Overwrite the local copy with a version merged from another device.
    func applyRemote(_ change: Change) async throws

    /// Provider version of each remote file we have already merged, keyed by
    /// file name. Lets a sync skip files that have not changed.
    func mergedVersions() async throws -> [String: String]
    func setMergedVersion(_ file: String, version: String) async throws

    /// Newest clock we had when our own file was last uploaded. Anything newer
    /// than this means the folder is behind the device.
    func lastUploadedHlc() async throws -> String?
    func setLastUploadedHlc(_ hlc: String) async throws

    /// Newest clock this device has seen, across every record.
    ///
    /// Seeds the clock at launch so it cannot restart behind its own previous
    /// edits after the system clock moves backwards.
    func newestHlc() async throws -> String?

    /// Wipe every local record and all sync bookkeeping.
    ///
    /// Called when the connected folder changes: records carry no account, so
    /// without this one person's notes would be uploaded into another's Drive.
    func clearAll() async throws
}

public struct ChangeKey: Hashable, Sendable {
    public let entity: Entity
    public let id: String
    public init(entity: Entity, id: String) {
        self.entity = entity
        self.id = id
    }
}

public extension Change {
    var key: ChangeKey { ChangeKey(entity: entity, id: id) }

    /// The device that authored this version, read out of its clock.
    var authorNode: String? { HybridLogicalClock.decode(hlc)?.node }
}

/// Reference implementation used by tests and previews.
public actor InMemoryStore: LocalStore {
    private var records: [ChangeKey: Change] = [:]
    private var versions: [String: String] = [:]
    private var uploaded: String?

    public init() {}

    public func changesAuthored(by node: String) throws -> [Change] {
        records.values.filter { $0.authorNode == node }
    }

    public func recordLocal(_ change: Change) throws {
        records[change.key] = change
    }

    public func currentHlc(_ entity: Entity, _ id: String) throws -> String? {
        records[ChangeKey(entity: entity, id: id)]?.hlc
    }

    public func applyRemote(_ change: Change) throws {
        records[change.key] = change
    }

    public func mergedVersions() throws -> [String: String] { versions }

    public func setMergedVersion(_ file: String, version: String) throws {
        versions[file] = version
    }

    public func lastUploadedHlc() throws -> String? { uploaded }

    public func setLastUploadedHlc(_ hlc: String) throws { uploaded = hlc }

    public func newestHlc() throws -> String? {
        records.values.map(\.hlc).max()
    }

    public func clearAll() throws {
        records.removeAll()
        versions.removeAll()
        uploaded = nil
    }

    // MARK: Test helpers

    public func record(_ entity: Entity, _ id: String) -> Change? {
        records[ChangeKey(entity: entity, id: id)]
    }

    public func allRecords() -> [Change] { Array(records.values) }
}
