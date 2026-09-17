import Foundation
import SwiftUI
import Network
import MyNoteCore

/// Decides *when* to sync. `SyncEngine` decides how.
///
/// The rule this enforces: an edit is saved locally and the user moves on. Sync
/// is a background consequence, never something typing waits for.
@Observable
@MainActor
final class SyncCoordinator {
    enum Status: Equatable {
        case idle
        case syncing
        case offline
        case paused(reason: String)
        case error(String)

        var isSyncing: Bool { self == .syncing }
    }

    private(set) var status: Status = .idle
    private(set) var lastSyncedAt: Date?
    private(set) var pendingCount = 0

    let engine: SyncEngine
    private let store: SwiftDataStore
    private let purchases: PurchaseManager

    private var debounceTask: Task<Void, Never>?
    private var monitor: NWPathMonitor?
    private var isOnline = true

    /// Long enough to batch a burst of typing, short enough that switching
    /// devices feels immediate.
    private let debounce: Duration = .seconds(2)

    init(store: SwiftDataStore, api: APIClient, purchases: PurchaseManager) {
        self.store = store
        self.purchases = purchases
        self.engine = SyncEngine(store: store, api: api, deviceId: Self.deviceId)
        startNetworkMonitor()
    }

    /// Stable per-install id, used as the HLC node so two devices never produce
    /// the same clock. Not tied to identifierForVendor, which changes on reinstall
    /// and would make old edits look like they came from a stranger.
    static var deviceId: String {
        let key = "sync.deviceId"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let fresh = String(UUID().uuidString.prefix(8))
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }

    /// Call after any local edit. Coalesces a burst into a single round trip.
    func scheduleSync() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: self?.debounce ?? .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    func syncNow() async {
        guard purchases.canSync else {
            status = .paused(reason: "Sync is part of MyNote Sync")
            return
        }
        guard isOnline else {
            status = .offline
            return
        }
        guard !status.isSyncing else { return }

        status = .syncing
        let result = await engine.sync()
        await refreshPendingCount()

        switch result {
        case .success(let outcome):
            lastSyncedAt = .now
            status = .idle
            if !outcome.rejected.isEmpty {
                // Rejected changes are a bug on our side, not the user's; log
                // loudly rather than showing a scary message.
                print("sync rejected \(outcome.rejected.count) change(s): \(outcome.rejected)")
            }
        case .failure(.offline):
            status = .offline
        case .failure(.subscriptionRequired):
            status = .paused(reason: "Sync is part of MyNote Sync")
        case .failure(.unauthenticated):
            status = .paused(reason: "Sign in to sync")
        case .failure(let error):
            status = .error(Self.message(for: error))
        }
    }

    func refreshPendingCount() async {
        pendingCount = (try? await store.outbox(limit: 999).count) ?? 0
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

    private static func message(for error: APIError) -> String {
        switch error {
        case .quotaExceeded(let m): return m
        case .conflict(let m):      return m
        case .server(_, _, let m):  return m
        case .decoding:             return "Couldn't read the server's reply."
        default:                    return "Sync failed. We'll retry."
        }
    }
}
