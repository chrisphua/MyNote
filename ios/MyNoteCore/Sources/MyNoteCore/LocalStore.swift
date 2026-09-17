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

    /// Drop outbox entries the server has accepted (or permanently rejected).
    func removeFromOutbox(_ keys: [ChangeKey]) async throws

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

    public func removeFromOutbox(_ keys: [ChangeKey]) throws {
        let dropped = Set(keys)
        for key in dropped { pending.removeValue(forKey: key) }
        pendingOrder.removeAll { dropped.contains($0) }
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
