import Foundation
import SwiftData
import MyNoteCore

/// `LocalStore` backed by SwiftData.
///
/// A `ModelActor` so it owns its own `ModelContext` on its own executor — a
/// context must never be touched from two tasks, and sync runs off the main
/// actor so typing is never blocked by a network round trip.
@ModelActor
actor SwiftDataStore: LocalStore {

    // MARK: - Cursor

    func cursor() throws -> Int {
        try state().cursor
    }

    func setCursor(_ value: Int) throws {
        let s = try state()
        s.cursor = value
        s.lastSyncedAt = .now
        try modelContext.save()
    }

    private func state() throws -> SyncState {
        var descriptor = FetchDescriptor<SyncState>()
        descriptor.fetchLimit = 1
        if let existing = try modelContext.fetch(descriptor).first { return existing }
        let fresh = SyncState()
        modelContext.insert(fresh)
        return fresh
    }

    // MARK: - Outbox

    func outbox(limit: Int) throws -> [Change] {
        var descriptor = FetchDescriptor<OutboxEntry>(
            sortBy: [SortDescriptor(\.queuedAt, order: .forward)]
        )
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor).compactMap(Self.change(from:))
    }

    func enqueue(_ change: Change) throws {
        try writeRecord(change)

        let fields = String(
            data: (try? JSONEncoder().encode(change.fields)) ?? Data("{}".utf8),
            encoding: .utf8
        ) ?? "{}"

        let key = "\(change.entity.rawValue):\(change.id)"
        var descriptor = FetchDescriptor<OutboxEntry>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1

        if let existing = try modelContext.fetch(descriptor).first {
            // Collapse rapid keystrokes into one pending change rather than
            // queueing an entry per character.
            existing.hlc = change.hlc
            existing.deleted = change.deleted
            existing.fieldsJSON = fields
        } else {
            modelContext.insert(OutboxEntry(
                entity: change.entity.rawValue,
                recordId: change.id,
                hlc: change.hlc,
                deleted: change.deleted,
                fieldsJSON: fields
            ))
        }
        try modelContext.save()
    }

    func removeFromOutbox(_ keys: [ChangeKey]) throws {
        guard !keys.isEmpty else { return }
        let encoded = Set(keys.map { "\($0.entity.rawValue):\($0.id)" })
        for entry in try modelContext.fetch(FetchDescriptor<OutboxEntry>())
        where encoded.contains(entry.key) {
            modelContext.delete(entry)
        }
        try modelContext.save()
    }

    // MARK: - Records

    func currentHlc(_ entity: Entity, _ id: String) throws -> String? {
        switch entity {
        case .note:       return try fetchNote(id)?.hlc
        case .block:      return try fetchBlock(id)?.hlc
        case .theme:      return try fetchTheme(id)?.hlc
        case .attachment: return nil   // attachments carry no local row yet
        }
    }

    func applyRemote(_ change: Change) throws {
        try writeRecord(change)
        try modelContext.save()
    }

    private func writeRecord(_ change: Change) throws {
        switch change.entity {
        case .note:
            if let row = try fetchNote(change.id) {
                if !change.deleted {
                    row.title = change.fields.string("title") ?? row.title
                    row.icon = change.fields.string("icon")
                    row.parentId = change.fields.string("parent_id")
                    row.orderKey = change.fields.string("order_key") ?? row.orderKey
                }
                row.hlc = change.hlc
                row.deleted = change.deleted
                row.updatedAt = .now
            } else if let note = Note(change: change) {
                modelContext.insert(NoteEntity(
                    id: note.id, title: note.title, icon: note.icon, parentId: note.parentId,
                    orderKey: note.orderKey, hlc: note.hlc, deleted: note.deleted
                ))
            } else if change.deleted {
                // Tombstone for a note we never had: record it so a later pull
                // cannot resurrect the delete.
                modelContext.insert(NoteEntity(
                    id: change.id, title: "", icon: nil, parentId: nil,
                    orderKey: "", hlc: change.hlc, deleted: true
                ))
            }

        case .block:
            if let row = try fetchBlock(change.id) {
                if !change.deleted {
                    row.noteId = change.fields.string("note_id") ?? row.noteId
                    row.parentId = change.fields.string("parent_id")
                    row.orderKey = change.fields.string("order_key") ?? row.orderKey
                    row.type = change.fields.string("type") ?? row.type
                    row.content = change.fields.string("content") ?? row.content
                }
                row.hlc = change.hlc
                row.deleted = change.deleted
                row.updatedAt = .now
            } else if let block = Block(change: change) {
                modelContext.insert(BlockEntity(
                    id: block.id, noteId: block.noteId, parentId: block.parentId,
                    orderKey: block.orderKey, type: block.type.rawValue,
                    content: block.content.encoded(), hlc: block.hlc, deleted: block.deleted
                ))
            } else if change.deleted {
                modelContext.insert(BlockEntity(
                    id: change.id, noteId: "", parentId: nil, orderKey: "",
                    type: BlockType.paragraph.rawValue, content: "{}",
                    hlc: change.hlc, deleted: true
                ))
            }

        case .theme:
            if let row = try fetchTheme(change.id) {
                if !change.deleted {
                    row.name = change.fields.string("name") ?? row.name
                    row.spec = change.fields.string("spec") ?? row.spec
                }
                row.hlc = change.hlc
                row.deleted = change.deleted
            } else {
                modelContext.insert(ThemeEntity(
                    id: change.id,
                    name: change.fields.string("name") ?? "Theme",
                    spec: change.fields.string("spec") ?? "{}",
                    hlc: change.hlc,
                    deleted: change.deleted
                ))
            }

        case .attachment:
            break
        }
    }

    private func fetchNote(_ id: String) throws -> NoteEntity? {
        var d = FetchDescriptor<NoteEntity>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try modelContext.fetch(d).first
    }

    private func fetchBlock(_ id: String) throws -> BlockEntity? {
        var d = FetchDescriptor<BlockEntity>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try modelContext.fetch(d).first
    }

    private func fetchTheme(_ id: String) throws -> ThemeEntity? {
        var d = FetchDescriptor<ThemeEntity>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try modelContext.fetch(d).first
    }

    private static func change(from entry: OutboxEntry) -> Change? {
        guard let entity = Entity(rawValue: entry.entity) else { return nil }
        let fields = (try? JSONDecoder().decode(
            [String: JSONValue].self,
            from: Data(entry.fieldsJSON.utf8)
        )) ?? [:]
        return Change(entity: entity, id: entry.recordId, hlc: entry.hlc,
                      deleted: entry.deleted, fields: fields)
    }
}
