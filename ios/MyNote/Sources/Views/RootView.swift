import SwiftUI
import SwiftData
import MyNoteCore

/// Top-level layout.
///
/// One `NavigationSplitView` serves every screen size: it collapses to a stack
/// on an iPhone and shows sidebar-plus-detail on an iPad or a landscape Max,
/// which is why there is no size-class branching here. The places that *do*
/// need to adapt (content width, toolbar density) read the size class directly.
struct RootView: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(ThemeManager.self) private var theme

    @State private var selectedNoteId: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var showingSettings = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            NoteListView(selectedNoteId: $selectedNoteId, showingSettings: $showingSettings)
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 420)
        } detail: {
            if let selectedNoteId {
                NoteEditorView(noteId: selectedNoteId)
                    // Rebuild the editor when the note changes so SwiftUI does
                    // not reuse focus state across two different documents.
                    .id(selectedNoteId)
            } else {
                EmptyStateView()
            }
        }
        .background(theme.current.background)
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .task { await app.start() }
        .onChange(of: app.purchases.entitlements) { _, _ in
            app.applyEntitlements()
        }
    }
}

private struct EmptyStateView: View {
    @Environment(ThemeManager.self) private var theme

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text")
                .font(.system(size: 40))
                .foregroundStyle(theme.current.textSecondary)
            Text("Pick a note, or start a new one.")
                .font(theme.current.font(.body))
                .foregroundStyle(theme.current.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.current.background)
    }
}
