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
        try await store.enqueue(change("b1", "0000000000000064-0000-devA", text: "local"))
        try await store.removeFromOutbox([ChangeKey(entity: .block, id: "b1")])

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
