import Foundation
import SwiftData
import MyNoteCore

/// `LocalStore` backed by SwiftData.
///
/// A `ModelActor` so it owns its own `ModelContext` on its own executor — a
/// context must never be touched from two tasks, and sync runs off the main
/// actor so typing is never blocked by a network round trip.
///
/// This database is the source of truth. The file in the user's cloud folder is
/// a projection of it, so a failed upload delays a backup but can never lose an
/// edit.
@ModelActor
actor SwiftDataStore: LocalStore {

    // MARK: - Records

    func changesAuthored(by node: String) throws -> [Change] {
        var changes: [Change] = []

        let notes = try modelContext.fetch(
            FetchDescriptor<NoteEntity>(predicate: #Predicate { $0.authorNode == node })
        )
        changes += notes.map {
            Note(id: $0.id, title: $0.title, icon: $0.icon, parentId: $0.parentId,
                 orderKey: $0.orderKey, hlc: $0.hlc, deleted: $0.deleted).asChange()
        }

        let blocks = try modelContext.fetch(
            FetchDescriptor<BlockEntity>(predicate: #Predicate { $0.authorNode == node })
        )
        changes += blocks.compactMap { row in
            guard let type = BlockType(rawValue: row.type) else { return nil }
            return Block(id: row.id, noteId: row.noteId, parentId: row.parentId,
                         orderKey: row.orderKey, type: type,
                         content: BlockContent.decode(row.content),
                         hlc: row.hlc, deleted: row.deleted).asChange()
        }

        let themes = try modelContext.fetch(
            FetchDescriptor<ThemeEntity>(predicate: #Predicate { $0.authorNode == node })
        )
        changes += themes.map {
            Change(entity: .theme, id: $0.id, hlc: $0.hlc, deleted: $0.deleted,
                   fields: ["name": .string($0.name), "spec": .string($0.spec)])
        }

        return changes
    }

    func recordLocal(_ change: Change) throws {
        try writeRecord(change)
        try modelContext.save()
    }

    func applyRemote(_ change: Change) throws {
        try writeRecord(change)
        try modelContext.save()
    }

    func currentHlc(_ entity: Entity, _ id: String) throws -> String? {
        switch entity {
        case .note:       return try fetchNote(id)?.hlc
        case .block:      return try fetchBlock(id)?.hlc
        case .theme:      return try fetchTheme(id)?.hlc
        case .attachment: return nil   // attachments carry no local row yet
        }
    }

    // MARK: - Sync bookkeeping

    func mergedVersions() throws -> [String: String] {
        let rows = try modelContext.fetch(FetchDescriptor<RemoteVersion>())
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.fileName, $0.version) })
    }

    func setMergedVersion(_ file: String, version: String) throws {
        var descriptor = FetchDescriptor<RemoteVersion>(predicate: #Predicate { $0.fileName == file })
        descriptor.fetchLimit = 1
        if let existing = try modelContext.fetch(descriptor).first {
            existing.version = version
        } else {
            modelContext.insert(RemoteVersion(fileName: file, version: version))
        }
        try modelContext.save()
    }

    func lastUploadedHlc() throws -> String? {
        try meta().lastUploadedHlc
    }

    func setLastUploadedHlc(_ hlc: String) throws {
        let row = try meta()
        row.lastUploadedHlc = hlc
        row.lastSyncedAt = .now
        try modelContext.save()
    }

    func newestHlc() throws -> String? {
        var newest: String?
        func consider(_ candidate: String?) {
            guard let candidate else { return }
            if newest == nil || candidate > newest! { newest = candidate }
        }
        for row in try modelContext.fetch(FetchDescriptor<NoteEntity>()) { consider(row.hlc) }
        for row in try modelContext.fetch(FetchDescriptor<BlockEntity>()) { consider(row.hlc) }
        for row in try modelContext.fetch(FetchDescriptor<ThemeEntity>()) { consider(row.hlc) }
        return newest
    }

    func clearAll() throws {
        // Records carry no account. Connecting a different folder without this
        // would upload one person's notes into another's Drive.
        try modelContext.delete(model: NoteEntity.self)
        try modelContext.delete(model: BlockEntity.self)
        try modelContext.delete(model: ThemeEntity.self)
        try modelContext.delete(model: RemoteVersion.self)
        try modelContext.delete(model: SyncMeta.self)
        try modelContext.save()
    }

    // MARK: - App-facing helpers

    func lastSyncedAt() throws -> Date? { try meta().lastSyncedAt }

    func connectedProvider() throws -> String? { try meta().connectedProvider }

    func setConnectedProvider(_ provider: String?) throws {
        try meta().connectedProvider = provider
        try modelContext.save()
    }

    /// Custom themes that arrived from another device. Themes sync like any
    /// other record, but the theme picker reads its own store.
    func syncedThemes() throws -> [ThemeSpec] {
        try modelContext
            .fetch(FetchDescriptor<ThemeEntity>())
            .filter { !$0.deleted }
            .compactMap { ThemeSpec.decode($0.spec)?.sanitized() }
    }

    func blockIds(inNote noteId: String) throws -> [String] {
        try modelContext
            .fetch(FetchDescriptor<BlockEntity>(
                predicate: #Predicate { $0.noteId == noteId && !$0.deleted }
            ))
            .map(\.id)
    }

    // MARK: - Writing

    private func writeRecord(_ change: Change) throws {
        let author = HybridLogicalClock.decode(change.hlc)?.node ?? ""

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
                row.authorNode = author
                row.deleted = change.deleted
                row.updatedAt = .now
            } else if let note = Note(change: change) {
                modelContext.insert(NoteEntity(
                    id: note.id, title: note.title, icon: note.icon, parentId: note.parentId,
                    orderKey: note.orderKey, hlc: note.hlc, deleted: note.deleted
                ))
            } else if change.deleted {
                // Tombstone for a note we never had: record it so a later merge
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
                row.authorNode = author
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
                row.authorNode = author
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

    private func meta() throws -> SyncMeta {
        var descriptor = FetchDescriptor<SyncMeta>()
        descriptor.fetchLimit = 1
        if let existing = try modelContext.fetch(descriptor).first { return existing }
        let fresh = SyncMeta()
        modelContext.insert(fresh)
        return fresh
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
}
