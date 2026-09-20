import SwiftUI
import SwiftData
import MyNoteCore

struct NoteListView: View {
    @Binding var selectedNoteId: String?
    @Binding var showingSettings: Bool

    @Environment(AppEnvironment.self) private var app
    @Environment(ThemeManager.self) private var theme

    // Tombstoned notes stay in the database for sync but never in the list.
    // Sorted in Swift below for the same reason as the editor: a fractional
    // index needs code-point comparison, which the store's collation is not.
    @Query(filter: #Predicate<NoteEntity> { !$0.deleted })
    private var notes: [NoteEntity]

    @State private var searchText = ""

    private var repository: NoteRepository {
        NoteRepository(store: app.store, coordinator: app.syncCoordinator)
    }

    private var filtered: [NoteEntity] {
        let ordered = notes.sorted { $0.orderKey < $1.orderKey }
        guard !searchText.isEmpty else { return ordered }
        return ordered.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        List(selection: $selectedNoteId) {
            ForEach(filtered) { note in
                NoteRow(note: note)
                    .tag(note.id)
                    .listRowBackground(theme.current.background)
            }
            .onDelete(perform: delete)
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(theme.current.background)
        .searchable(text: $searchText, prompt: "Search notes")
        .navigationTitle("MyNote")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task {
                        let id = await repository.createNote()
                        selectedNoteId = id
                    }
                } label: {
                    Label("New note", systemImage: "square.and.pencil")
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                Button { showingSettings = true } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        .overlay(alignment: .center) {
            if filtered.isEmpty {
                Text(searchText.isEmpty ? "No notes yet." : "Nothing matches “\(searchText)”.")
                    .font(theme.current.font(.caption))
                    .foregroundStyle(theme.current.textSecondary)
            }
        }
        .safeAreaInset(edge: .bottom) {
            // Only appears when it has something worth saying. In the ordinary
            // case — notes saved, nothing pending — silence is the right answer,
            // and a permanent "Saved on this device" chip is just furniture.
            //
            // The padding and background live inside the view, so when it has
            // nothing to report the inset collapses to nothing rather than
            // leaving an empty strip.
            SyncStatusView(style: .banner)
        }
    }

    private func delete(at offsets: IndexSet) {
        let targets = offsets.map { filtered[$0] }
        Task {
            for note in targets {
                let blockIds = await blockIds(for: note.id)
                await repository.deleteNote(note.id, blockIds: blockIds)
                if selectedNoteId == note.id { selectedNoteId = nil }
            }
        }
    }

    private func blockIds(for noteId: String) async -> [String] {
        (try? await app.store.blockIds(inNote: noteId)) ?? []
    }
}

private struct NoteRow: View {
    let note: NoteEntity
    @Environment(ThemeManager.self) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(note.title.isEmpty ? "Untitled" : note.title)
                .font(theme.current.font(.body))
                .foregroundStyle(theme.current.textPrimary)
                .lineLimit(1)
            Text(note.updatedAt, format: .relative(presentation: .named))
                .font(theme.current.font(.caption))
                .foregroundStyle(theme.current.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }
}

/// Whether edits have left the device.
///
/// Two modes. In the note list it stays silent unless something needs
/// attention; in Settings it always reports, because that is where someone goes
/// to check deliberately.
struct SyncStatusView: View {
    enum Style {
        /// Always reports, with no chrome. For Settings.
        case inline
        /// Silent unless something needs attention; carries its own padding and
        /// background so it collapses to nothing when quiet.
        case banner
    }

    var style: Style = .inline

    @Environment(AppEnvironment.self) private var app
    @Environment(ThemeManager.self) private var theme

    var body: some View {
        if let state = state {
            let row = HStack(spacing: 6) {
                if state.showsSpinner {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: state.symbol)
                }
                Text(state.message)
            }
            .font(theme.current.font(.caption))
            .foregroundStyle(state.isProblem ? Color.orange : theme.current.textSecondary)

            switch style {
            case .inline:
                row
            case .banner:
                row
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, theme.current.contentPadding)
                    .padding(.vertical, 8)
                    .background(.bar)
            }
        }
    }

    private struct Status {
        let message: String
        let symbol: String
        var showsSpinner = false
        var isProblem = false
        /// True for the steady state, which the list hides and Settings shows.
        var isQuiet = false
    }

    private var state: Status? {
        let coordinator = app.syncCoordinator
        let status: Status

        switch coordinator.status {
        case .syncing:
            status = Status(message: "Backing up…", symbol: "arrow.triangle.2.circlepath",
                            showsSpinner: true)
        case .offline:
            status = coordinator.hasPendingChanges
                ? Status(message: "Offline — changes waiting", symbol: "wifi.slash")
                : Status(message: "Offline", symbol: "wifi.slash", isQuiet: true)
        case .needsSignIn:
            status = Status(message: "Reconnect \(coordinator.provider.title)",
                            symbol: "person.crop.circle.badge.exclamationmark", isProblem: true)
        case .storageFull:
            status = Status(message: "\(coordinator.provider.title) is full",
                            symbol: "externaldrive.badge.exclamationmark", isProblem: true)
        case .error(let message):
            status = Status(message: message, symbol: "exclamationmark.triangle", isProblem: true)
        case .localOnly:
            status = Status(message: "Saved on this device", symbol: "iphone", isQuiet: true)
        case .idle:
            if coordinator.hasPendingChanges {
                status = Status(message: "Changes waiting", symbol: "arrow.triangle.2.circlepath")
            } else if let at = coordinator.lastSyncedAt {
                status = Status(message: "Backed up \(at.formatted(.relative(presentation: .named)))",
                                symbol: "checkmark.icloud", isQuiet: true)
            } else {
                status = Status(message: "Saved on this device", symbol: "externaldrive", isQuiet: true)
            }
        }

        return (style == .banner && status.isQuiet) ? nil : status
    }
}

func relativeTime(_ date: Date) -> String {
    date.formatted(.relative(presentation: .named))
}
