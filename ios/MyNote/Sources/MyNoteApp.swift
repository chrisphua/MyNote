import SwiftUI
import SwiftData
import MyNoteCore

@main
struct MyNoteApp: App {
    @State private var app = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .environment(app.themeManager)
                .tint(app.themeManager.current.accentColor)
                .preferredColorScheme(app.themeManager.colorSchemeOverride)
        }
        .modelContainer(app.modelContainer)
    }
}
