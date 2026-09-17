import Foundation
import Testing
@testable import MyNoteCore

/// An in-memory stand-in for Google Drive or iCloud Drive.
///
/// Records every write so tests can assert *which* file a device touched — the
/// central safety property is that a device only ever writes its own.
actor FakeFolder: RemoteFolder {
    nonisolated var displayName: String { "Fake Drive" }

    private var files: [String: Data] = [:]
    private var versions: [String: String] = [:]
    private var revision = 0
    private(set) var writtenNames: [String] = []
    private(set) var readNames: [String] = []
    var failure: RemoteFolderError?

    func list() async throws -> [RemoteFile] {
        if let failure { throw failure }
        return files.map { name, data in
            RemoteFile(name: name, modifiedAt: .now, size: data.count,
                       version: versions[name] ?? "0")
        }
    }

    func read(_ name: String) async throws -> Data {
        if let failure { throw failure }
        readNames.append(name)
        guard let data = files[name] else { throw RemoteFolderError.notFound(name) }
        return data
    }

    func write(_ name: String, data: Data) async throws {
        if let failure { throw failure }
        revision += 1
        files[name] = data
        versions[name] = String(revision)
        writtenNames.append(name)
    }

    func delete(_ name: String) async throws {
        files.removeValue(forKey: name)
        versions.removeValue(forKey: name)
    }

    /// Drop a file in as if another device had written it.
    func seed(deviceId: String, changes: [Change]) throws {
        let file = DeviceFile(deviceId: deviceId, updatedAt: 0, changes: changes)
        revision += 1
        let name = DeviceFile.fileName(for: deviceId)
        files[name] = try file.encoded()
        versions[name] = String(revision)
    }

    func setFailure(_ error: RemoteFolderError?) { failure = error }
}

private func block(_ id: String, _ hlc: String, text: String = "x", deleted: Bool = false) -> Change {
    Change(entity: .block, id: id, hlc: hlc, deleted: deleted,
           fields: ["note_id": .string("n1"), "order_key": .string("V"),
                    "type": .string("paragraph"),
                    "content": .string(BlockContent(text: text).encoded())])
}

/// `<millis hex>-<counter hex>-<device>` — the device id is the clock's node,
/// which is also what decides whose file a record belongs in.
private func hlc(_ millis: Int64, device: String) -> String {
    HybridLogicalClock(millis: millis, counter: 0, node: device).encoded
}

@Suite("Folder sync")
struct FolderSyncTests {

    @Test("writes this device's records into its own file")
    func uploadsAuthoredRecords() async throws {
        let store = InMemoryStore()
        let folder = FakeFolder()
        let sync = FolderSync(store: store, deviceId: "phone", folder: folder)

        try await sync.record(block("b1", await sync.stamp(), text: "hello"))
        let outcome = try #require(try? (await sync.sync()).get())

        #expect(outcome.uploaded == 1)
        #expect(await folder.writtenNames == ["device-phone.json"])
    }

    @Test("never writes another device's file")
    func writesOnlyItsOwnFile() async throws {
        // This is what removes write conflicts entirely: no file has two writers,
        // so there is nothing to lock and nothing to merge on write.
        let store = InMemoryStore()
        let folder = FakeFolder()
        try await folder.seed(deviceId: "tablet", changes: [block("b9", hlc(500, device: "tablet"))])

        let sync = FolderSync(store: store, deviceId: "phone", folder: folder)
        try await sync.record(block("b1", await sync.stamp()))
        _ = await sync.sync()

        let written = await folder.writtenNames
        #expect(written.allSatisfy { $0 == "device-phone.json" })
    }

    @Test("merges records another device wrote")
    func mergesRemoteDevice() async throws {
        let store = InMemoryStore()
        let folder = FakeFolder()
        try await folder.seed(deviceId: "tablet", changes: [
            block("b1", hlc(1000, device: "tablet"), text: "from the tablet"),
        ])

        let sync = FolderSync(store: store, deviceId: "phone", folder: folder)
        let outcome = try #require(try? (await sync.sync()).get())

        #expect(outcome.merged == 1)
        let stored = try #require(await store.record(.block, "b1"))
        #expect(BlockContent.decode(stored.fields.string("content")!).text == "from the tablet")
    }

    @Test("the newer clock wins when two devices edited the same block")
    func lastWriteWins() async throws {
        let store = InMemoryStore()
        let folder = FakeFolder()
        let sync = FolderSync(store: store, deviceId: "phone", folder: folder)

        // The phone edited at t=2000; the tablet's copy is older.
        try await sync.record(block("b1", hlc(2000, device: "phone"), text: "newer, from phone"))
        try await folder.seed(deviceId: "tablet", changes: [
            block("b1", hlc(1000, device: "tablet"), text: "older, from tablet"),
        ])

        _ = await sync.sync()

        let stored = try #require(await store.record(.block, "b1"))
        #expect(BlockContent.decode(stored.fields.string("content")!).text == "newer, from phone")
    }

    @Test("an older local copy loses to a newer remote one")
    func remoteCanWin() async throws {
        let store = InMemoryStore()
        let folder = FakeFolder()
        let sync = FolderSync(store: store, deviceId: "phone", folder: folder)

        try await sync.record(block("b1", hlc(1000, device: "phone"), text: "older"))
        try await folder.seed(deviceId: "tablet", changes: [
            block("b1", hlc(3000, device: "tablet"), text: "newer"),
        ])

        _ = await sync.sync()

        let stored = try #require(await store.record(.block, "b1"))
        #expect(BlockContent.decode(stored.fields.string("content")!).text == "newer")
    }

    @Test("does not re-download a file that has not changed")
    func skipsUnchangedFiles() async throws {
        let store = InMemoryStore()
        let folder = FakeFolder()
        try await folder.seed(deviceId: "tablet", changes: [block("b1", hlc(1000, device: "tablet"))])
        let sync = FolderSync(store: store, deviceId: "phone", folder: folder)

        _ = await sync.sync()
        let afterFirst = await folder.readNames.count

        let second = try #require(try? (await sync.sync()).get())
        #expect(await folder.readNames.count == afterFirst, "re-read an unchanged file")
        #expect(second.skipped == 1)
    }

    @Test("picks the file back up once it changes again")
    func reReadsChangedFiles() async throws {
        let store = InMemoryStore()
        let folder = FakeFolder()
        try await folder.seed(deviceId: "tablet", changes: [block("b1", hlc(1000, device: "tablet"))])
        let sync = FolderSync(store: store, deviceId: "phone", folder: folder)
        _ = await sync.sync()

        try await folder.seed(deviceId: "tablet", changes: [
            block("b1", hlc(4000, device: "tablet"), text: "edited later"),
        ])
        let outcome = try #require(try? (await sync.sync()).get())

        #expect(outcome.merged == 1)
    }

    @Test("an edit made while a backup is uploading is still pending afterwards")
    func editDuringUploadSurvives() async throws {
        // The local database is the source of truth and the file is a projection
        // of it, so there is no queue an in-flight edit can be deleted from. This
        // asserts the property that replaces the old outbox invariant.
        let store = InMemoryStore()
        let folder = FakeFolder()
        let sync = FolderSync(store: store, deviceId: "phone", folder: folder)

        try await sync.record(block("b1", hlc(1000, device: "phone"), text: "first"))
        _ = await sync.sync()
        #expect(await sync.hasPendingChanges() == false)

        // A keystroke that lands after the upload read the records.
        try await sync.record(block("b1", hlc(5000, device: "phone"), text: "typed later"))
        #expect(await sync.hasPendingChanges(), "the newer edit must still be queued for upload")

        _ = await sync.sync()
        #expect(await sync.hasPendingChanges() == false)
    }

    @Test("a failed upload loses nothing")
    func failedUploadKeepsEverything() async throws {
        let store = InMemoryStore()
        let folder = FakeFolder()
        let sync = FolderSync(store: store, deviceId: "phone", folder: folder)

        try await sync.record(block("b1", await sync.stamp(), text: "precious"))
        await folder.setFailure(.offline)

        let result = await sync.sync()
        #expect(result == .failure(.offline))
        #expect(await sync.state == .offline)
        #expect(await sync.hasPendingChanges())

        await folder.setFailure(nil)
        _ = await sync.sync()
        #expect(await sync.hasPendingChanges() == false)
    }

    @Test("reports when no folder is connected rather than failing obscurely")
    func notConnected() async {
        let sync = FolderSync(store: InMemoryStore(), deviceId: "phone", folder: nil)
        #expect(await sync.state == .notConnected)
        #expect(await sync.sync() == .failure(.notConnected))
    }

    @Test("surfaces a full Drive as its own state")
    func storageFull() async throws {
        let folder = FakeFolder()
        let sync = FolderSync(store: InMemoryStore(), deviceId: "phone", folder: folder)
        try await sync.record(block("b1", await sync.stamp()))
        await folder.setFailure(.storageFull)

        _ = await sync.sync()
        #expect(await sync.state == .storageFull)
    }

    @Test("a deletion propagates as a tombstone")
    func mergesDeletes() async throws {
        let store = InMemoryStore()
        let folder = FakeFolder()
        try await folder.seed(deviceId: "tablet", changes: [
            Change(entity: .block, id: "b1", hlc: hlc(2000, device: "tablet"), deleted: true),
        ])

        let sync = FolderSync(store: store, deviceId: "phone", folder: folder)
        _ = await sync.sync()

        #expect(await store.record(.block, "b1")?.deleted == true)
    }

    @Test("a record taken over by another device leaves our file")
    func authorshipFollowsTheClock() async throws {
        let store = InMemoryStore()
        let folder = FakeFolder()
        let sync = FolderSync(store: store, deviceId: "phone", folder: folder)

        try await sync.record(block("b1", hlc(1000, device: "phone"), text: "mine"))
        #expect(try await store.changesAuthored(by: "phone").count == 1)

        // The tablet edits it later, so the newest version is now theirs.
        try await folder.seed(deviceId: "tablet", changes: [
            block("b1", hlc(9000, device: "tablet"), text: "theirs"),
        ])
        _ = await sync.sync()

        #expect(try await store.changesAuthored(by: "phone").isEmpty,
                "we should stop republishing a record another device now owns")
    }

    @Test("the clock resumes above the newest local edit after a relaunch")
    func clockSeedsFromStore() async throws {
        let store = InMemoryStore()
        let ahead = hlc(200_000_000_000_000, device: "phone")
        try await store.recordLocal(block("b1", ahead))

        let sync = FolderSync(store: store, deviceId: "phone", folder: FakeFolder())
        #expect(await sync.stamp() > ahead)
    }

    @Test("connecting a different folder leaves nothing behind")
    func clearAllWipesEverything() async throws {
        let store = InMemoryStore()
        try await store.recordLocal(block("b1", hlc(1000, device: "phone")))
        try await store.setMergedVersion("device-tablet.json", version: "7")
        try await store.setLastUploadedHlc(hlc(1000, device: "phone"))

        try await store.clearAll()

        #expect(await store.allRecords().isEmpty)
        #expect(try await store.mergedVersions().isEmpty)
        #expect(try await store.lastUploadedHlc() == nil)
    }

    @Test("a backup written by a newer app version is refused, not misread")
    func rejectsNewerFormat() throws {
        var file = DeviceFile(deviceId: "tablet", updatedAt: 0, changes: [])
        file.format = DeviceFile.currentFormat + 1
        let data = try JSONEncoder().encode(file)

        #expect(throws: RemoteFolderError.self) {
            _ = try DeviceFile.decode(data)
        }
    }

    @Test("device file names round-trip")
    func fileNaming() {
        #expect(DeviceFile.fileName(for: "abc123") == "device-abc123.json")
        #expect(DeviceFile.deviceId(fromFileName: "device-abc123.json") == "abc123")
        #expect(DeviceFile.deviceId(fromFileName: "license.json") == nil)
        #expect(DeviceFile.deviceId(fromFileName: "notes.txt") == nil)
    }
}
