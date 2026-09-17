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

        let container = modelContainer
        store = SwiftDataStore(modelContainer: container)
        auth = AuthManager()
        purchases = PurchaseManager()
        themeManager = ThemeManager()

        let authRef = auth
        let api = APIClient(baseURL: Self.apiBaseURL) { [authRef] in
            try await authRef.idToken()
        }
        syncCoordinator = SyncCoordinator(store: store, api: api, purchases: purchases)
    }
}
