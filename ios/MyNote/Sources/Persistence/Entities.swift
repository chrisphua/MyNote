import Foundation
import SwiftData
import MyNoteCore

/// SwiftData mirrors of the core models.
///
/// These are storage types, not domain types: `MyNoteCore` owns the domain so
/// the sync engine stays testable without SwiftData. Each entity keeps the `hlc`
/// it was last written with, which is what makes local merge decisions possible.

@Model
final class NoteEntity {
    @Attribute(.unique) var id: String
    var title: String
    var icon: String?
    var parentId: String?
    var orderKey: String
    var hlc: String
    var deleted: Bool
    var updatedAt: Date

    init(id: String, title: String, icon: String?, parentId: String?,
         orderKey: String, hlc: String, deleted: Bool) {
        self.id = id
        self.title = title
        self.icon = icon
        self.parentId = parentId
        self.orderKey = orderKey
        self.hlc = hlc
        self.deleted = deleted
        self.updatedAt = .now
    }
}

@Model
final class BlockEntity {
    @Attribute(.unique) var id: String
    var noteId: String
    var parentId: String?
    var orderKey: String
    var type: String
    /// JSON, matching `blocks.content` on the server.
    var content: String
    var hlc: String
    var deleted: Bool
    var updatedAt: Date

    init(id: String, noteId: String, parentId: String?, orderKey: String,
         type: String, content: String, hlc: String, deleted: Bool) {
        self.id = id
        self.noteId = noteId
        self.parentId = parentId
        self.orderKey = orderKey
        self.type = type
        self.content = content
        self.hlc = hlc
        self.deleted = deleted
        self.updatedAt = .now
    }
}

@Model
final class ThemeEntity {
    @Attribute(.unique) var id: String
    var name: String
    var spec: String
    var hlc: String
    var deleted: Bool

    init(id: String, name: String, spec: String, hlc: String, deleted: Bool) {
        self.id = id
        self.name = name
        self.spec = spec
        self.hlc = hlc
        self.deleted = deleted
    }
}

/// A local edit waiting to reach the server.
///
/// Persisting the outbox is what makes the app genuinely offline-first: edits
/// made in airplane mode survive a force-quit and a reboot.
@Model
final class OutboxEntry {
    @Attribute(.unique) var key: String      // "<entity>:<id>"
    var entity: String
    var recordId: String
    var hlc: String
    var deleted: Bool
    var fieldsJSON: String
    var queuedAt: Date

    init(entity: String, recordId: String, hlc: String, deleted: Bool, fieldsJSON: String) {
        self.key = "\(entity):\(recordId)"
        self.entity = entity
        self.recordId = recordId
        self.hlc = hlc
        self.deleted = deleted
        self.fieldsJSON = fieldsJSON
        self.queuedAt = .now
    }
}

@Model
final class SyncState {
    @Attribute(.unique) var singleton: String = "state"
    var cursor: Int
    var lastSyncedAt: Date?

    init(cursor: Int = 0) {
        self.cursor = cursor
    }
}
