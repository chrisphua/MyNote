import Foundation
import SwiftData
import SwiftUI
import MyNoteCore

/// Wires the app's long-lived objects together.
///
/// Deliberately constructed eagerly at launch so the editor never has to wait on
/// setup: notes are local files first, and the network is an optional extra.
@Observable
@MainActor
final class AppEnvironment {
    let modelContainer: ModelContainer
    let store: SwiftDataStore
    let auth: AuthManager
    let purchases: PurchaseManager
    let themeManager: ThemeManager
    let syncCoordinator: SyncCoordinator
    let api: APIClient

    /// Which account the local database currently belongs to. Local rows carry
    /// no uid, so this is how we notice the account changed underneath them.
    private static let ownerKey = "local.ownerUid"

    /// Base URL of the Worker. Overridden per build configuration.
    static var apiBaseURL: URL {
        if let raw = Bundle.main.object(forInfoDictionaryKey: "MyNoteAPIBaseURL") as? String,
           let url = URL(string: raw) {
            return url
        }
        return URL(string: "https://mynote-api.workers.dev")!
    }

    init() {
        let schema = Schema([NoteEntity.self, BlockEntity.self, ThemeEntity.self,
                             OutboxEntry.self, SyncState.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            modelContainer = try ModelContainer(for: schema, configurations: config)
        } catch {
            // A corrupt local database must not brick the app; fall back to
            // memory so the user can at least export and reinstall.
            assertionFailure("persistent store unavailable: \(error)")
            modelContainer = try! ModelContainer(
                for: schema,
                configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            )
        }

        store = SwiftDataStore(modelContainer: modelContainer)
        auth = AuthManager()
        purchases = PurchaseManager()
        themeManager = ThemeManager()

        let authRef = auth
        api = APIClient(baseURL: Self.apiBaseURL) { [authRef] in
            try await authRef.idToken()
        }
        syncCoordinator = SyncCoordinator(store: store, api: api, purchases: purchases)

        // StoreKit confirms a purchase happened; the server is what makes it
        // portable. Without this the transaction is never reported, no
        // entitlement row is ever written, and a paying iOS user gets 402 from
        // sync forever.
        let apiRef = api
        purchases.configure { [apiRef] transactionId in
            try await apiRef.verifyAppleTransaction(id: transactionId)
        }
    }

    /// Run once the UI is up: adopt the server's view of what this account owns,
    /// reconcile the local database with who is signed in, and load any themes
    /// that arrived from another device.
    func start() async {
        await purchases.loadProducts()
        await purchases.refreshLocalEntitlements()
        await reconcileAccount()
        await refreshEntitlements()
        loadSyncedThemes()
        await syncCoordinator.refreshPendingCount()
        await syncCoordinator.syncNow()
    }

    /// The server is authoritative across platforms — it is the only place that
    /// knows about a purchase made on Android. Called at launch and whenever the
    /// signed-in account changes.
    func refreshEntitlements() async {
        if case .signedIn(let uid, _) = auth.status {
            purchases.setBuyer(uid: uid)
        } else {
            purchases.setBuyer(uid: nil)
        }
        guard auth.isSignedIn else { return }
        do {
            purchases.applyServerEntitlements(try await api.entitlements())
        } catch {
            // Offline, or the account has none yet. StoreKit's local view still
            // applies, so a purchase made on this device keeps working.
        }
        themeManager.canEdit = purchases.canCustomizeThemes
    }

    /// Wipe local data when the signed-in account changes.
    ///
    /// Local rows carry no uid. Without this, signing out of A and into B would
    /// push A's queued notes into B's account, and B would inherit A's cursor
    /// and never pull its own records.
    func reconcileAccount() async {
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: Self.ownerKey)
        let current: String? = {
            if case .signedIn(let uid, _) = auth.status { return uid }
            return nil
        }()

        // Signing out on its own leaves the data with its owner, so it is still
        // there when they sign back in. Only a *different* account wipes.
        guard let current, current != previous else {
            if let current { defaults.set(current, forKey: Self.ownerKey) }
            return
        }

        if previous != nil {
            try? await store.clearAll()
            themeManager.forgetSyncedThemes()
        }
        defaults.set(current, forKey: Self.ownerKey)
    }

    /// Themes sync as ordinary records, but the theme picker reads its own
    /// store, so they are handed across explicitly.
    func loadSyncedThemes() {
        Task {
            guard let specs = try? await store.syncedThemes() else { return }
            themeManager.mergeSynced(specs)
        }
    }
}
