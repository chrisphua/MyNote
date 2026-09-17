import Foundation

public struct SyncOutcome: Equatable, Sendable {
    public var pushed: Int
    public var pulled: Int
    public var rejected: [Rejection]
    public var cursor: Int

    public static let noop = SyncOutcome(pushed: 0, pulled: 0, rejected: [], cursor: 0)
}

/// Drives one sync pass: push what we changed, pull what changed elsewhere.
///
/// The engine is deliberately dumb about *when* it runs. Editing always writes
/// locally first and returns immediately; this runs afterwards, and failing is
/// normal (the device is on a plane). Nothing here is allowed to lose a local
/// edit: an entry leaves the outbox only once the server has confirmed it.
public actor SyncEngine {
    public enum State: Equatable, Sendable {
        case idle
        case syncing
        case offline
        case needsSubscription
        case failed(String)
    }

    private let store: LocalStore
    private let api: any SyncAPI
    private let batchSize: Int
    private var clock: HybridLogicalClock
    private var didSeedClock = false

    public private(set) var state: State = .idle

    public init(store: LocalStore, api: any SyncAPI, deviceId: String, batchSize: Int = 400) {
        self.store = store
        self.api = api
        self.batchSize = batchSize
        self.clock = HybridLogicalClock.now(node: deviceId)
    }

    /// Stamp a local edit. Always call this rather than building an hlc by hand,
    /// so the device's clock stays monotonic across edits.
    public func stamp() async -> String {
        await seedClockIfNeeded()
        return clock.tick(now: Int64(Date().timeIntervalSince1970 * 1000))
    }

    /// Bring the clock up to the newest edit this device already knows about.
    ///
    /// The in-memory clock starts from wall time, and wall time can move
    /// backwards between launches — a timezone fix, an NTP correction, a manual
    /// change. Without this, the next edit would stamp *below* the server's copy,
    /// the server's `excluded.hlc > hlc` guard would silently no-op it, and the
    /// local copy would diverge permanently.
    private func seedClockIfNeeded() async {
        guard !didSeedClock else { return }
        didSeedClock = true
        guard let newest = try? await store.newestHlc(),
              let seen = HybridLogicalClock.decode(newest) else { return }
        clock.observe(seen, now: Int64(Date().timeIntervalSince1970 * 1000))
    }

    public func enqueue(_ change: Change) async throws {
        try await store.enqueue(change)
    }

    @discardableResult
    public func sync() async -> Result<SyncOutcome, APIError> {
        await seedClockIfNeeded()
        state = .syncing
        var totalPushed = 0
        var totalPulled = 0
        var allRejected: [Rejection] = []
        var cursor = (try? await store.cursor()) ?? 0

        // Loop until the server says there is nothing left, so a device coming
        // back after a long time offline catches up in one call.
        while true {
            let pending: [Change]
            do {
                pending = try await store.outbox(limit: batchSize)
            } catch {
                state = .failed("could not read local outbox")
                return .failure(.decoding("outbox unavailable"))
            }

            let response: SyncResponse
            do {
                response = try await api.sync(cursor: cursor, changes: pending, limit: nil)
            } catch let error as APIError {
                state = Self.state(for: error)
                return .failure(error)
            } catch {
                state = .offline
                return .failure(.offline)
            }

            do {
                try await apply(response)
            } catch {
                state = .failed("could not write synced changes")
                return .failure(.decoding("local write failed"))
            }

            // Everything we sent is now resolved: accepted, or rejected as
            // permanently invalid (retrying those would loop forever). Hand the
            // batch back so the store can drop each row only if it still holds
            // the version we pushed.
            let rejectedKeys = Set(response.rejected.map { ChangeKey(entity: $0.entity, id: $0.id) })
            do {
                try await store.removeFromOutbox(pending)
            } catch {
                // Swallowing this would leave the batch queued with nothing left
                // to pull, and the loop below would re-push it forever.
                state = .failed("could not update the local queue")
                return .failure(.decoding("outbox update failed"))
            }

            totalPushed += pending.count - rejectedKeys.count
            totalPulled += response.changes.count
            allRejected += response.rejected
            cursor = response.cursor

            let outboxDrained = (try? await store.outbox(limit: 1).isEmpty) ?? true
            if !response.hasMore && outboxDrained { break }
        }

        state = .idle
        return .success(SyncOutcome(pushed: totalPushed, pulled: totalPulled,
                                    rejected: allRejected, cursor: cursor))
    }

    private func apply(_ response: SyncResponse) async throws {
        for change in response.changes {
            // The server has already resolved conflicts, but a local edit made
            // *while this request was in flight* can still be newer. Re-checking
            // here is what stops sync from clobbering a fresh keystroke.
            let local = try await store.currentHlc(change.entity, change.id)
            if let local, local >= change.hlc { continue }
            try await store.applyRemote(change)

            if let remoteClock = HybridLogicalClock.decode(change.hlc) {
                clock.observe(remoteClock, now: Int64(Date().timeIntervalSince1970 * 1000))
            }
        }
        // Persist the cursor only after every change in the page is durable, so
        // a crash mid-apply replays the page instead of skipping it.
        try await store.setCursor(response.cursor)
    }

    private static func state(for error: APIError) -> State {
        switch error {
        case .offline:                return .offline
        case .subscriptionRequired:   return .needsSubscription
        case .unauthenticated:        return .failed("signed out")
        case .quotaExceeded(let m), .conflict(let m):
            return .failed(m)
        case .server(_, _, let m):    return .failed(m)
        case .decoding(let m):        return .failed(m)
        }
    }
}
