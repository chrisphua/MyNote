import Foundation
import Testing
@testable import MyNoteCore

/// A scripted stand-in for the Worker. Records what was pushed so tests can
/// assert on the engine's behaviour rather than on network plumbing.
actor FakeAPI: SyncAPI {
    var responses: [SyncResponse]
    var error: APIError?
    private(set) var pushedBatches: [[Change]] = []

    init(responses: [SyncResponse] = [], error: APIError? = nil) {
        self.responses = responses
        self.error = error
    }

    func sync(cursor: Int, changes: [Change], limit: Int?) async throws -> SyncResponse {
        pushedBatches.append(changes)
        if let error { throw error }
        guard !responses.isEmpty else {
            return SyncResponse(cursor: cursor, changes: [], hasMore: false,
                                serverTime: 0, rejected: [])
        }
        return responses.removeFirst()
    }
}

private func change(_ id: String, _ hlc: String, text: String = "x", deleted: Bool = false) -> Change {
    Change(entity: .block, id: id, hlc: hlc, deleted: deleted,
           fields: ["note_id": .string("n1"), "order_key": .string("a0"),
                    "type": .string("paragraph"),
                    "content": .string(BlockContent(text: text).encoded())])
}

private func response(cursor: Int, changes: [Change] = [], hasMore: Bool = false,
                      rejected: [Rejection] = []) -> SyncResponse {
    SyncResponse(cursor: cursor, changes: changes, hasMore: hasMore,
                 serverTime: 0, rejected: rejected)
}

@Suite("Sync engine")
struct SyncEngineTests {
    @Test("pushes queued edits and clears the outbox on success")
    func pushesAndClears() async throws {
        let store = InMemoryStore()
        let api = FakeAPI(responses: [response(cursor: 5)])
        let engine = SyncEngine(store: store, api: api, deviceId: "devA")

        try await engine.enqueue(change("b1", await engine.stamp()))
        let result = await engine.sync()

        #expect(try! result.get().pushed == 1)
        #expect(try await store.outbox(limit: 10).isEmpty)
        #expect(try await store.cursor() == 5)
    }

    @Test("keeps the edit queued when the network is down")
    func keepsOutboxOffline() async throws {
        let store = InMemoryStore()
        let api = FakeAPI(error: .offline)
        let engine = SyncEngine(store: store, api: api, deviceId: "devA")

        try await engine.enqueue(change("b1", await engine.stamp()))
        let result = await engine.sync()

        // Losing the edit here would be data loss, so it must survive.
        #expect(result == .failure(.offline))
        #expect(try await store.outbox(limit: 10).count == 1)
        #expect(await engine.state == .offline)
    }

    @Test("surfaces a missing subscription as its own state, not a generic failure")
    func paywall() async throws {
        let store = InMemoryStore()
        let api = FakeAPI(error: .subscriptionRequired)
        let engine = SyncEngine(store: store, api: api, deviceId: "devA")

        _ = await engine.sync()
        #expect(await engine.state == .needsSubscription)
    }

    @Test("applies a remote change that is newer than the local copy")
    func appliesNewerRemote() async throws {
        let store = InMemoryStore()
        let existing = change("b1", "0000000000000064-0000-devA", text: "local")
        try await store.enqueue(existing)
        try await store.removeFromOutbox([existing])

        let remote = change("b1", "00000000000000c8-0000-devB", text: "remote")
        let api = FakeAPI(responses: [response(cursor: 3, changes: [remote])])
        let engine = SyncEngine(store: store, api: api, deviceId: "devA")

        _ = await engine.sync()
        let stored = await store.record(.block, "b1")!
        #expect(BlockContent.decode(stored.fields.string("content")!).text == "remote")
    }

    @Test("does not clobber a local edit made while the request was in flight")
    func doesNotClobberNewerLocal() async throws {
        let store = InMemoryStore()
        // Local copy is newer than what the server is about to hand back.
        try await store.enqueue(change("b1", "0000000000000190-0000-devA", text: "just typed"))

        let stale = change("b1", "0000000000000064-0000-devB", text: "stale server copy")
        let api = FakeAPI(responses: [response(cursor: 9, changes: [stale])])
        let engine = SyncEngine(store: store, api: api, deviceId: "devA")

        _ = await engine.sync()
        let stored = await store.record(.block, "b1")!
        #expect(BlockContent.decode(stored.fields.string("content")!).text == "just typed")
    }

    @Test("drops permanently rejected changes instead of retrying forever")
    func dropsRejected() async throws {
        let store = InMemoryStore()
        let api = FakeAPI(responses: [
            response(cursor: 1, rejected: [Rejection(entity: .block, id: "b1", reason: "bad_block_type")])
        ])
        let engine = SyncEngine(store: store, api: api, deviceId: "devA")

        try await engine.enqueue(change("b1", await engine.stamp()))
        let outcome = try! (await engine.sync()).get()

        #expect(outcome.rejected.count == 1)
        #expect(try await store.outbox(limit: 10).isEmpty, "a rejected change must not loop")
    }

    @Test("keeps pulling until the server has nothing left")
    func drainsPages() async throws {
        let store = InMemoryStore()
        let api = FakeAPI(responses: [
            response(cursor: 10, changes: [change("b1", "0000000000000064-0000-devB")], hasMore: true),
            response(cursor: 20, changes: [change("b2", "0000000000000065-0000-devB")], hasMore: false),
        ])
        let engine = SyncEngine(store: store, api: api, deviceId: "devA")

        let outcome = try! (await engine.sync()).get()
        #expect(outcome.pulled == 2)
        #expect(try await store.cursor() == 20)
    }

    @Test("applies a tombstone")
    func appliesDelete() async throws {
        let store = InMemoryStore()
        let api = FakeAPI(responses: [
            response(cursor: 4, changes: [
                Change(entity: .block, id: "b1", hlc: "00000000000000c8-0000-devB", deleted: true)
            ])
        ])
        let engine = SyncEngine(store: store, api: api, deviceId: "devA")

        _ = await engine.sync()
        #expect(await store.record(.block, "b1")?.deleted == true)
    }

    @Test("stamps each local edit with a strictly increasing clock")
    func monotonicStamps() async {
        let engine = SyncEngine(store: InMemoryStore(), api: FakeAPI(), deviceId: "devA")
        var previous = ""
        for _ in 0..<500 {
            let next = await engine.stamp()
            #expect(next > previous)
            previous = next
        }
    }
}

/// Runs a side effect during the *first* request only, to reproduce a user
/// typing while a push is in flight. Records every batch it was sent.
actor RacingAPI: SyncAPI {
    private let duringFirstFlight: @Sendable () async -> Void
    private var calls = 0
    private(set) var pushedBatches: [[Change]] = []

    init(duringFirstFlight: @escaping @Sendable () async -> Void) {
        self.duringFirstFlight = duringFirstFlight
    }

    func sync(cursor: Int, changes: [Change], limit: Int?) async throws -> SyncResponse {
        pushedBatches.append(changes)
        calls += 1
        if calls == 1 { await duringFirstFlight() }
        return SyncResponse(cursor: cursor + changes.count, changes: [],
                            hasMore: false, serverTime: 0, rejected: [])
    }
}

@Suite("Sync engine — the in-flight edit")
struct SyncEngineRaceTests {

    @Test("an edit made during a push still reaches the server")
    func inFlightEditIsNotLost() async throws {
        let store = InMemoryStore()
        let laterHlc = "0000000000000190-0000-devA"

        // The outbox collapses edits to one row per record, so a keystroke
        // landing mid-request overwrites the very row being confirmed. Removing
        // by key alone would delete it here, unsent and unrecoverable.
        let api = RacingAPI {
            try? await store.enqueue(change("b1", laterHlc, text: "typed during push"))
        }
        let engine = SyncEngine(store: store, api: api, deviceId: "devA")

        try await engine.enqueue(change("b1", "0000000000000064-0000-devA", text: "first"))
        _ = await engine.sync()

        // The engine keeps going while the outbox is non-empty, so the newer
        // edit goes out on the next pass rather than being dropped.
        let batches = await api.pushedBatches
        let everySentHlc = batches.flatMap { $0 }.map(\.hlc)
        #expect(everySentHlc.contains(laterHlc),
                "the edit made during the push was never sent to the server")

        // And once it has been confirmed, nothing is left queued.
        #expect(try await store.outbox(limit: 10).isEmpty)
    }

    @Test("the version that was actually pushed is removed")
    func confirmedVersionIsRemoved() async throws {
        let store = InMemoryStore()
        let api = FakeAPI(responses: [response(cursor: 5)])
        let engine = SyncEngine(store: store, api: api, deviceId: "devA")

        try await engine.enqueue(change("b1", await engine.stamp()))
        _ = await engine.sync()

        #expect(try await store.outbox(limit: 10).isEmpty)
    }

    @Test("the clock resumes above the newest local edit after a relaunch")
    func clockSeedsFromStore() async throws {
        let store = InMemoryStore()
        // An edit stamped far in the future of the wall clock — what a backwards
        // system-clock change leaves behind.
        let ahead = "0000200000000000-0000-devA"
        try await store.enqueue(change("b1", ahead))

        // A fresh engine, as after a relaunch.
        let engine = SyncEngine(store: store, api: FakeAPI(), deviceId: "devA")
        let next = await engine.stamp()

        #expect(next > ahead, "a new stamp must sort above edits this device already made")
    }

    @Test("signing into a different account leaves nothing behind")
    func clearAllWipesEverything() async throws {
        let store = InMemoryStore()
        try await store.enqueue(change("b1", "0000000000000064-0000-devA", text: "previous account"))
        try await store.setCursor(99)

        try await store.clearAll()

        #expect(try await store.outbox(limit: 10).isEmpty)
        #expect(try await store.cursor() == 0)
        #expect(await store.record(.block, "b1") == nil)
    }
}
