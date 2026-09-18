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

        // CloudKit mirroring must be switched off explicitly.
        //
        // `ModelConfiguration` defaults to `.automatic`, which turns mirroring
        // ON as soon as it finds an iCloud entitlement — and this app has one,
        // for iCloud *Drive* documents. CloudKit then rejects the schema,
        // because it supports neither unique constraints nor non-optional
        // attributes without defaults, and this app relies on both. The store
        // fails to load and the app dies on launch.
        //
        // It cannot reproduce in a simulator, where the entitlement has no
        // effect, so it only ever appears on a real device.
        //
        // MyNote does not use CloudKit at all: backups are plain files written
        // into the user's own Drive folder. See docs/BACKUP-FORMAT.md.
        let onDisk = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none
        )
        let inMemory = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )

        do {
            modelContainer = try ModelContainer(for: schema, configurations: onDisk)
        } catch {
            // A corrupt local database must not brick the app; fall back to
            // memory so the user can still write, and still reach Settings to
            // reconnect a backup that has their notes in it.
            print("MyNote: persistent store unavailable, running in memory — \(error)")
            do {
                modelContainer = try ModelContainer(for: schema, configurations: inMemory)
            } catch {
                // Nothing left to fall back to: an in-memory store cannot fail
                // for any reason the app could recover from.
                fatalError("MyNote could not open any note store: \(error)")
            }
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

        // After the folder has been read, so a restored backup wins over the
        // welcome note rather than being buried under it.
        if !ProcessInfo.processInfo.arguments.contains("-ui-testing") {
            let existing = (try? await store.noteCount()) ?? 0
            await NoteRepository(store: store, coordinator: syncCoordinator)
                .seedWelcomeNoteIfNeeded(existingNoteCount: existing)
        }

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
