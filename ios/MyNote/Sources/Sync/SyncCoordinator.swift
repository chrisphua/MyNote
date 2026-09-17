import Foundation
import SwiftUI
import Network
import MyNoteCore

/// Which storage the notes are backed up to.
enum StorageProvider: String, CaseIterable, Identifiable, Sendable {
    case none
    case iCloud
    case googleDrive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none:        "This device only"
        case .iCloud:      "iCloud Drive"
        case .googleDrive: "Google Drive"
        }
    }

    var detail: String {
        switch self {
        case .none:
            "Notes stay on this iPhone. Nothing leaves it."
        case .iCloud:
            "Already signed in. Syncs with your iPad and Mac — but Apple provides no way for an Android app to read iCloud Drive."
        case .googleDrive:
            "Works on iPhone, iPad and Android. Choose this if you use both."
        }
    }

    var symbol: String {
        switch self {
        case .none:        "iphone"
        case .iCloud:      "icloud"
        case .googleDrive: "externaldrive.badge.person.crop"
        }
    }
}

/// Decides *when* to back up. `FolderSync` decides how.
///
/// The rule this enforces: an edit is saved locally and the user moves on.
/// Backing up is a background consequence, never something typing waits for.
@Observable
@MainActor
final class SyncCoordinator {
    enum Status: Equatable {
        case localOnly
        case idle
        case syncing
        case offline
        case needsSignIn
        case storageFull
        case error(String)

        var isSyncing: Bool { self == .syncing }
    }

    private(set) var status: Status = .localOnly
    private(set) var provider: StorageProvider = .none
    private(set) var lastSyncedAt: Date?
    private(set) var hasPendingChanges = false

    let engine: FolderSync
    private let store: SwiftDataStore
    private let googleAuth: GoogleAuth
    /// Kept alongside the engine so the licence file can be read and written
    /// without reaching into the sync actor.
    private var folder: (any RemoteFolder)?

    /// Set by the app once purchases are known. Free users may still connect a
    /// folder to restore a backup and to discover a licence bought on the other
    /// platform — uploading is what Pro unlocks.
    var uploadsAllowed = false

    private var debounceTask: Task<Void, Never>?
    private var monitor: NWPathMonitor?
    private var isOnline = true

    /// Long enough to batch a burst of typing, short enough that picking up the
    /// other device feels current. Longer than the old server sync: a whole-file
    /// upload is heavier than a delta, so it is worth coalescing more.
    private let debounce: Duration = .seconds(5)

    init(store: SwiftDataStore, googleAuth: GoogleAuth) {
        self.store = store
        self.googleAuth = googleAuth
        self.engine = FolderSync(store: store, deviceId: Self.deviceId)
        startNetworkMonitor()
    }

    /// Stable per-install id, used as the HLC node and as this device's file
    /// name. Not derived from a hardware identifier: those need permissions and
    /// can be shared between a phone and its clone.
    static var deviceId: String {
        let key = "sync.deviceId"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let fresh = String(UUID().uuidString.prefix(8)).lowercased()
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }

    // MARK: - Provider

    func restoreProvider() async {
        let saved = (try? await store.connectedProvider()).flatMap { $0 }
        await select(StorageProvider(rawValue: saved ?? "") ?? .none, confirmSwitch: false)
        lastSyncedAt = try? await store.lastSyncedAt()
        await refreshPending()
    }

    /// Connect a storage provider. `confirmSwitch` is the caller's promise that
    /// the user agreed to move their notes, since changing folders wipes local
    /// data to avoid mixing two people's notes together.
    func select(_ provider: StorageProvider, confirmSwitch: Bool = true) async {
        let previous = self.provider
        self.provider = provider

        if confirmSwitch, previous != .none, previous != provider {
            // Records carry no account. Keeping them would upload one person's
            // notes into another's Drive.
            try? await store.clearAll()
        }
        try? await store.setConnectedProvider(provider == .none ? nil : provider.rawValue)

        switch provider {
        case .none:
            folder = nil
            await engine.connect(nil)
            status = .localOnly

        case .iCloud:
            guard ICloudDriveFolder.isAvailable() else {
                status = .needsSignIn
                return
            }
            folder = ICloudDriveFolder()
            await engine.connect(folder)
            status = .idle
            await syncNow()

        case .googleDrive:
            guard googleAuth.isSignedIn else {
                status = .needsSignIn
                return
            }
            folder = GoogleDriveFolder(auth: googleAuth)
            await engine.connect(folder)
            status = .idle
            await syncNow()
        }
    }

    func signInToGoogle() async {
        do {
            try await googleAuth.signIn()
            await select(.googleDrive)
        } catch {
            status = .error("Google sign-in was cancelled.")
        }
    }

    func disconnect() async {
        googleAuth.signOut()
        await select(.none)
    }

    // MARK: - Syncing

    /// Call after any local edit. Coalesces a burst into one upload.
    func scheduleSync() {
        guard provider != .none else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: self?.debounce ?? .seconds(5))
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    func syncNow() async {
        guard provider != .none else {
            status = .localOnly
            return
        }
        guard isOnline || provider == .iCloud else {
            // iCloud writes to a local folder and syncs itself, so it works
            // offline; Drive genuinely needs the network.
            status = .offline
            return
        }
        guard !status.isSyncing else { return }

        status = .syncing
        let result = await engine.sync(uploads: uploadsAllowed)
        await refreshPending()

        switch result {
        case .success:
            lastSyncedAt = .now
            status = .idle
        case .failure(.offline):
            status = .offline
        case .failure(.needsReauthentication):
            status = .needsSignIn
        case .failure(.storageFull):
            status = .storageFull
        case .failure(.notConnected):
            status = .localOnly
        case .failure(.notFound):
            status = .idle
        case .failure(.provider(let message)):
            status = .error(message)
        }
    }

    func refreshPending() async {
        hasPendingChanges = await engine.hasPendingChanges()
    }

    // MARK: - Licence

    /// Read the licence the user's other device left in the folder.
    ///
    /// This is the whole cross-platform purchase mechanism: no server, just a
    /// small file sitting beside the notes.
    func readLicense() async -> License? {
        guard let folder else { return nil }
        guard let data = try? await folder.read(License.fileName) else { return nil }
        return License.decode(data)
    }

    func writeLicense(_ license: License) async {
        guard let folder, let data = try? license.encoded() else { return }
        try? await folder.write(License.fileName, data: data)
    }

    private func startNetworkMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let wasOffline = !self.isOnline
                self.isOnline = path.status == .satisfied
                // Coming back online is exactly when a backlog should flush.
                if wasOffline && self.isOnline { await self.syncNow() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "io.mynote.network"))
        self.monitor = monitor
    }
}
