import Foundation

/// What the sync engine needs from local persistence.
///
/// Async because the real implementation is a SwiftData `ModelActor` — a
/// `ModelContext` is not thread-safe, so it has to own its own isolation. Tests
/// use `InMemoryStore`, which satisfies the same contract.
public protocol LocalStore: Sendable {
    /// Highest `serverSeq` this device has durably applied.
    func cursor() async throws -> Int
    func setCursor(_ value: Int) async throws

    /// Local edits not yet acknowledged by the server, oldest first.
    func outbox(limit: Int) async throws -> [Change]
    func enqueue(_ change: Change) async throws

    /// Drop outbox entries the server has resolved — accepted or permanently
    /// rejected — identified by the exact version that was sent.
    ///
    /// Removal is by `(key, hlc)`, never by key alone. Both stores collapse a
    /// burst of typing onto one outbox row, so a keystroke landing *while a push
    /// is in flight* overwrites that row with a newer clock. Deleting by key
    /// would drop the newer edit without ever having sent it: silent, permanent
    /// note loss.
    func removeFromOutbox(_ sent: [Change]) async throws

    /// Newest clock this device has seen, across records and the outbox.
    ///
    /// Used to seed the clock at launch so it cannot restart behind its own
    /// previous edits after the system clock moves backwards.
    func newestHlc() async throws -> String?

    /// Wipe every local record, the outbox and the cursor.
    ///
    /// Called when the signed-in account changes: local rows carry no `uid`, so
    /// without this the previous account's queued edits would be pushed into the
    /// new one.
    func clearAll() async throws

    /// The clock on our copy of a record, or nil if we have never seen it.
    func currentHlc(_ entity: Entity, _ id: String) async throws -> String?

    /// Overwrite the local copy with the server's version.
    func applyRemote(_ change: Change) async throws
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
}

/// Reference implementation used by tests and SwiftUI previews.
public actor InMemoryStore: LocalStore {
    private var records: [ChangeKey: Change] = [:]
    private var pending: [ChangeKey: Change] = [:]
    private var pendingOrder: [ChangeKey] = []
    private var cursorValue = 0

    public init() {}

    public func cursor() throws -> Int { cursorValue }

    public func setCursor(_ value: Int) throws { cursorValue = value }

    public func outbox(limit: Int) throws -> [Change] {
        pendingOrder.prefix(limit).compactMap { pending[$0] }
    }

    public func enqueue(_ change: Change) throws {
        records[change.key] = change
        if pending[change.key] == nil { pendingOrder.append(change.key) }
        pending[change.key] = change
    }

    public func removeFromOutbox(_ sent: [Change]) throws {
        for change in sent {
            // Only if this is still the version we pushed.
            guard pending[change.key]?.hlc == change.hlc else { continue }
            pending.removeValue(forKey: change.key)
            pendingOrder.removeAll { $0 == change.key }
        }
    }

    public func newestHlc() throws -> String? {
        (records.values.map(\.hlc) + pending.values.map(\.hlc)).max()
    }

    public func clearAll() throws {
        records.removeAll()
        pending.removeAll()
        pendingOrder.removeAll()
        cursorValue = 0
    }

    public func currentHlc(_ entity: Entity, _ id: String) throws -> String? {
        records[ChangeKey(entity: entity, id: id)]?.hlc
    }

    public func applyRemote(_ change: Change) throws {
        records[change.key] = change
    }

    // MARK: Test helpers

    public func record(_ entity: Entity, _ id: String) -> Change? {
        records[ChangeKey(entity: entity, id: id)]
    }

    public func allRecords() -> [Change] { Array(records.values) }
}
