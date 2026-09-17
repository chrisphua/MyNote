import Foundation
import MyNoteCore

/// Backup into the user's iCloud Drive.
///
/// The zero-friction option on Apple devices: no sign-in, no OAuth, no consent
/// screen — the account is already on the device. The folder is visible in the
/// Files app, so the notes are plainly the user's own.
///
/// It cannot reach Android. Apple publishes no iCloud Drive API for third-party
/// Android apps, so anyone who wants their notes on both platforms needs Google
/// Drive instead. The storage picker says so before they choose.
actor ICloudDriveFolder: RemoteFolder {
    nonisolated let displayName = "iCloud Drive"

    private let containerId: String?
    private var cachedRoot: URL?

    init(containerId: String? = nil) {
        self.containerId = containerId
    }

    /// True when the user is signed into iCloud and the container is reachable.
    static func isAvailable(containerId: String? = nil) -> Bool {
        FileManager.default.url(forUbiquityContainerIdentifier: containerId) != nil
    }

    private func root() throws -> URL {
        if let cachedRoot { return cachedRoot }

        // Returns nil when the user is signed out of iCloud, or has iCloud Drive
        // switched off for this app.
        guard let container = FileManager.default.url(forUbiquityContainerIdentifier: containerId) else {
            throw RemoteFolderError.needsReauthentication
        }

        // `Documents` is what the Files app shows. Anything outside it is hidden
        // from the user, which would be the wrong promise for "your own storage".
        let folder = container.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        cachedRoot = folder
        return folder
    }

    func list() async throws -> [RemoteFile] {
        let folder = try root()
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isUbiquitousItemKey]

        let urls = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )

        return urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let modified = values?.contentModificationDate ?? .distantPast
            let size = values?.fileSize ?? 0
            return RemoteFile(
                name: url.lastPathComponent,
                modifiedAt: modified,
                size: size,
                // iCloud has no etag we can read, so modification time plus size
                // stands in. It only has to change when the file does.
                version: "\(Int64(modified.timeIntervalSince1970 * 1000))-\(size)"
            )
        }
    }

    func read(_ name: String) async throws -> Data {
        let url = try root().appendingPathComponent(name)

        // A file written by another device may exist only as a placeholder until
        // it is pulled down. Reading without this returns "no such file".
        if (try? url.checkResourceIsReachable()) != true {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            try await waitForDownload(at: url)
        }

        return try await coordinatedRead(url)
    }

    func write(_ name: String, data: Data) async throws {
        let url = try root().appendingPathComponent(name)
        try await coordinatedWrite(url, data: data)
    }

    func delete(_ name: String) async throws {
        let url = try root().appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - File coordination

    /// iCloud can be syncing a file underneath us, so every access goes through
    /// `NSFileCoordinator` rather than reading the bytes directly.
    private func coordinatedRead(_ url: URL) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            var coordinatorError: NSError?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinatorError) { readURL in
                do {
                    continuation.resume(returning: try Data(contentsOf: readURL))
                } catch {
                    continuation.resume(throwing: RemoteFolderError.notFound(url.lastPathComponent))
                }
            }
            if let coordinatorError {
                continuation.resume(throwing: RemoteFolderError.provider(coordinatorError.localizedDescription))
            }
        }
    }

    private func coordinatedWrite(_ url: URL, data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var coordinatorError: NSError?
            NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinatorError) { writeURL in
                do {
                    try data.write(to: writeURL, options: .atomic)
                    continuation.resume()
                } catch {
                    let code = (error as NSError).code
                    // NSFileWriteOutOfSpaceError — the user's iCloud is full.
                    continuation.resume(throwing: code == NSFileWriteOutOfSpaceError
                                        ? RemoteFolderError.storageFull
                                        : RemoteFolderError.provider(error.localizedDescription))
                }
            }
            if let coordinatorError {
                continuation.resume(throwing: RemoteFolderError.provider(coordinatorError.localizedDescription))
            }
        }
    }

    /// Wait for a placeholder to materialise, with a ceiling so a stalled
    /// download cannot hang a sync forever.
    private func waitForDownload(at url: URL, timeout: Duration = .seconds(30)) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if (try? url.checkResourceIsReachable()) == true { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw RemoteFolderError.offline
    }
}
