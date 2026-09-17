import Foundation
import SwiftData
import SwiftUI
import MyNoteCore

/// Wires the app's long-lived objects together.
///
/// Constructed eagerly at launch so the editor never waits on setup: notes are
/// local files first, and any cloud folder is an optional extra.
@Observable
@MainActor
final class AppEnvironment {
    let modelContainer: ModelContainer
    let store: SwiftDataStore
    let purchases: PurchaseManager
    let themeManager: ThemeManager
    let syncCoordinator: SyncCoordinator
    let googleAuth: GoogleAuth

    /// OAuth client id for Google Drive, from `Info.plist`. Absent in a fresh
    /// clone, which simply means Drive is not offered — iCloud and local-only
    /// still work, and the app still builds and runs.
    static var googleClientId: String {
        Bundle.main.object(forInfoDictionaryKey: "MyNoteGoogleClientID") as? String ?? ""
    }

    static var isGoogleDriveConfigured: Bool { !googleClientId.isEmpty }

    init() {
        let schema = Schema([NoteEntity.self, BlockEntity.self, ThemeEntity.self,
                             RemoteVersion.self, SyncMeta.self])
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
        purchases = PurchaseManager()
        themeManager = ThemeManager()
        googleAuth = GoogleAuth(clientId: Self.googleClientId)
        syncCoordinator = SyncCoordinator(store: store, googleAuth: googleAuth)

        // A purchase on this device is written into the folder so the user's
        // other platform picks it up. There is no server to tell.
        let coordinator = syncCoordinator
        purchases.onPurchase = { license in
            Task { await coordinator.writeLicense(license) }
        }
    }

    /// Run once the UI is up.
    func start() async {
        await purchases.loadProducts()
        await purchases.refreshLocalEntitlements()
        applyEntitlements()

        await syncCoordinator.restoreProvider()

        // Read the licence *before* deciding whether uploads are allowed: this
        // is how a purchase made on Android unlocks the iPhone.
        purchases.applyRemoteLicense(await syncCoordinator.readLicense())
        applyEntitlements()

        loadSyncedThemes()
        await syncCoordinator.refreshPending()
    }

    /// Keep the theme gate and the upload gate in step with what the user owns.
    func applyEntitlements() {
        themeManager.canEdit = purchases.isPro
        syncCoordinator.uploadsAllowed = purchases.isPro
    }

    func loadSyncedThemes() {
        Task {
            guard let specs = try? await store.syncedThemes() else { return }
            themeManager.mergeSynced(specs)
        }
    }

    /// Delete every note on this device. Used when disconnecting storage, and
    /// offered explicitly in Settings.
    func eraseLocalData() async {
        try? await store.clearAll()
        themeManager.forgetSyncedThemes()
    }
}
