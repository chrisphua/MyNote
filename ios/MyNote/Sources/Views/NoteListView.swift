import SwiftUI
import SwiftData
import MyNoteCore

struct NoteListView: View {
    @Binding var selectedNoteId: String?
    @Binding var showingSettings: Bool

    @Environment(AppEnvironment.self) private var app
    @Environment(ThemeManager.self) private var theme

    // Tombstoned notes stay in the database for sync but never in the list.
    @Query(filter: #Predicate<NoteEntity> { !$0.deleted },
           sort: [SortDescriptor(\NoteEntity.orderKey)])
    private var notes: [NoteEntity]

    @State private var searchText = ""

    private var repository: NoteRepository {
        NoteRepository(store: app.store, coordinator: app.syncCoordinator)
    }

    private var filtered: [NoteEntity] {
        guard !searchText.isEmpty else { return notes }
        return notes.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
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
            ToolbarItem(placement: .status) {
                SyncStatusView()
            }
        }
        .overlay(alignment: .bottom) {
            if filtered.isEmpty {
                Text(searchText.isEmpty ? "No notes yet." : "Nothing matches “\(searchText)”.")
                    .font(theme.current.font(.caption))
                    .foregroundStyle(theme.current.textSecondary)
                    .padding(.bottom, 40)
            }
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
        let descriptor = FetchDescriptor<BlockEntity>(
            predicate: #Predicate { $0.noteId == noteId && !$0.deleted }
        )
        let context = ModelContext(app.modelContainer)
        return ((try? context.fetch(descriptor)) ?? []).map(\.id)
    }
}

private struct NoteRow: View {
    let note: NoteEntity
    @Environment(ThemeManager.self) private var theme

    var body: some View {
        HStack(spacing: 10) {
            Text(note.icon ?? "📄").font(.system(size: 18))
            VStack(alignment: .leading, spacing: 2) {
                Text(note.title.isEmpty ? "Untitled" : note.title)
                    .font(theme.current.font(.body))
                    .foregroundStyle(theme.current.textPrimary)
                    .lineLimit(1)
                Text(note.updatedAt, format: .relative(presentation: .named))
                    .font(theme.current.font(.caption))
                    .foregroundStyle(theme.current.textSecondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Small, always-visible truth about whether edits have left the device.
struct SyncStatusView: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(ThemeManager.self) private var theme

    var body: some View {
        let coordinator = app.syncCoordinator
        HStack(spacing: 6) {
            switch coordinator.status {
            case .syncing:
                ProgressView().controlSize(.mini)
                Text("Syncing…")
            case .offline:
                Image(systemName: "wifi.slash")
                Text(coordinator.pendingCount > 0
                     ? "^[\(coordinator.pendingCount) change](inflect: true) waiting"
                     : "Offline")
            case .paused(let reason):
                Image(systemName: "icloud.slash")
                Text(reason)
            case .error(let message):
                Image(systemName: "exclamationmark.triangle")
                Text(message)
            case .idle:
                if coordinator.pendingCount > 0 {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text("^[\(coordinator.pendingCount) change](inflect: true) waiting")
                } else if let at = coordinator.lastSyncedAt {
                    Image(systemName: "checkmark.icloud")
                    Text("Synced \(at, format: .relative(presentation: .named))")
                } else {
                    Image(systemName: "externaldrive")
                    Text("Saved on this device")
                }
            }
        }
        .font(theme.current.font(.caption))
        .foregroundStyle(theme.current.textSecondary)
    }
}
