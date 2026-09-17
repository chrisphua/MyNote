import Foundation

public struct SyncOutcome: Equatable, Sendable {
    /// Records written into our own file this pass.
    public var uploaded: Int
    /// Records merged in from other devices.
    public var merged: Int
    /// Device files skipped because they had not changed.
    public var skipped: Int

    public static let idle = SyncOutcome(uploaded: 0, merged: 0, skipped: 0)
}

/// Backs the notes up to the user's own cloud folder, and merges in whatever
/// their other devices have written.
///
/// The design that makes this safe without a server: **each device writes exactly
/// one file and never touches another's.** There is no file two devices can both
/// write, so there is no write conflict to resolve and no locking. Merging happens
/// on read, by hybrid logical clock — the same last-write-wins rule as before.
///
/// Failing is normal and cheap. The local database already holds every edit; a
/// failed sync only means the folder is briefly behind.
public actor FolderSync {
    public enum State: Equatable, Sendable {
        case idle
        case syncing
        case offline
        /// No folder connected — the app is local-only, which is a fine place to live.
        case notConnected
        case needsReauthentication
        case storageFull
        case failed(String)
    }

    private let store: LocalStore
    private let deviceId: String
    private var folder: (any RemoteFolder)?
    private var clock: HybridLogicalClock
    private var didSeedClock = false

    public private(set) var state: State = .notConnected

    public init(store: LocalStore, deviceId: String, folder: (any RemoteFolder)? = nil) {
        self.store = store
        self.deviceId = deviceId
        self.folder = folder
        self.clock = HybridLogicalClock.now(node: deviceId)
        self.state = folder == nil ? .notConnected : .idle
    }

    public func connect(_ folder: (any RemoteFolder)?) {
        self.folder = folder
        state = folder == nil ? .notConnected : .idle
    }

    public var isConnected: Bool { folder != nil }

    /// Stamp a local edit. Always use this rather than building a clock by hand.
    public func stamp() async -> String {
        await seedClockIfNeeded()
        return clock.tick(now: Int64(Date().timeIntervalSince1970 * 1000))
    }

    public func record(_ change: Change) async throws {
        try await store.recordLocal(change)
    }

    /// Bring the clock up to the newest edit this device already knows about.
    ///
    /// Wall time can move backwards between launches — a timezone fix, an NTP
    /// correction, a manual change. Without this the next edit would stamp below
    /// our own previous ones and lose to them on merge, permanently.
    private func seedClockIfNeeded() async {
        guard !didSeedClock else { return }
        didSeedClock = true
        guard let newest = try? await store.newestHlc(),
              let seen = HybridLogicalClock.decode(newest) else { return }
        clock.observe(seen, now: Int64(Date().timeIntervalSince1970 * 1000))
    }

    /// True when local records have moved on since our file was last written.
    public func hasPendingChanges() async -> Bool {
        guard let newest = try? await store.changesAuthored(by: deviceId).map(\.hlc).max() else {
            return false
        }
        let uploaded = (try? await store.lastUploadedHlc()) ?? nil
        guard let uploaded else { return true }
        return newest > uploaded
    }

    /// - Parameter uploads: when false, merge other devices' files but write
    ///   nothing. Lets someone restore a backup, and discover a licence bought on
    ///   the other platform, before they have paid.
    @discardableResult
    public func sync(uploads: Bool = true) async -> Result<SyncOutcome, RemoteFolderError> {
        await seedClockIfNeeded()

        guard let folder else {
            state = .notConnected
            return .failure(.notConnected)
        }

        state = .syncing
        do {
            let files = try await folder.list()
            let merged = try await pull(from: folder, files: files)
            let uploaded = uploads ? try await push(to: folder) : 0
            state = .idle
            return .success(SyncOutcome(uploaded: uploaded,
                                        merged: merged.count,
                                        skipped: merged.skipped))
        } catch let error as RemoteFolderError {
            state = Self.state(for: error)
            return .failure(error)
        } catch {
            state = .failed("Backup failed. We'll try again.")
            return .failure(.provider(String(describing: error)))
        }
    }

    // MARK: - Pull

    private func pull(
        from folder: any RemoteFolder,
        files: [RemoteFile]
    ) async throws -> (count: Int, skipped: Int) {
        let seen = (try? await store.mergedVersions()) ?? [:]
        var mergedCount = 0
        var skipped = 0

        for file in files {
            guard let author = DeviceFile.deviceId(fromFileName: file.name) else { continue }
            // Our own file is a projection of the local database; reading it back
            // could only ever tell us what we already know.
            guard author != deviceId else { continue }

            // Unchanged since the last merge: downloading it again would cost the
            // user bandwidth to learn nothing.
            if seen[file.name] == file.version {
                skipped += 1
                continue
            }

            let data = try await folder.read(file.name)
            let decoded = try DeviceFile.decode(data)

            for change in decoded.changes {
                // Same last-write-wins rule as before: only a strictly newer
                // clock may overwrite what we have.
                let local = try await store.currentHlc(change.entity, change.id)
                if let local, local >= change.hlc { continue }
                try await store.applyRemote(change)
                mergedCount += 1

                if let remoteClock = HybridLogicalClock.decode(change.hlc) {
                    clock.observe(remoteClock, now: Int64(Date().timeIntervalSince1970 * 1000))
                }
            }

            // Recorded only after every change in the file is durable, so an
            // interrupted merge replays the file rather than skipping it.
            try await store.setMergedVersion(file.name, version: file.version)
        }

        return (mergedCount, skipped)
    }

    // MARK: - Push

    private func push(to folder: any RemoteFolder) async throws -> Int {
        let mine = try await store.changesAuthored(by: deviceId)
        guard let newest = mine.map(\.hlc).max() else { return 0 }

        let uploaded = try await store.lastUploadedHlc()
        if let uploaded, newest <= uploaded { return 0 }   // folder already current

        let file = DeviceFile(
            deviceId: deviceId,
            updatedAt: Int64(Date().timeIntervalSince1970 * 1000),
            changes: mine
        )
        try await folder.write(DeviceFile.fileName(for: deviceId), data: try file.encoded())

        // Only after the write lands. If it failed, the records stay "pending"
        // and go up next time — nothing is lost either way.
        try await store.setLastUploadedHlc(newest)
        return mine.count
    }

    private static func state(for error: RemoteFolderError) -> State {
        switch error {
        case .notConnected:           return .notConnected
        case .needsReauthentication:  return .needsReauthentication
        case .storageFull:            return .storageFull
        case .offline:                return .offline
        case .notFound:               return .idle   // nothing uploaded yet
        case .provider(let message):  return .failed(message)
        }
    }
}
