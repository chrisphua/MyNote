import Foundation
import SwiftData
import MyNoteCore

/// SwiftData mirrors of the core models.
///
/// Storage types, not domain types: `MyNoteCore` owns the domain so the sync
/// engine stays testable without SwiftData. Each row keeps the `hlc` it was last
/// written with — that is what makes local merge decisions possible — and the
/// `authorNode` from inside that clock, so "everything this device owns" is an
/// indexed query rather than a scan.

@Model
final class NoteEntity {
    @Attribute(.unique) var id: String
    var title: String
    var icon: String?
    var parentId: String?
    var orderKey: String
    var hlc: String
    /// Device that wrote the current version; decoded from `hlc` on write.
    var authorNode: String
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
        self.authorNode = HybridLogicalClock.decode(hlc)?.node ?? ""
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
    /// JSON, matching the `content` field on the wire.
    var content: String
    var hlc: String
    var authorNode: String
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
        self.authorNode = HybridLogicalClock.decode(hlc)?.node ?? ""
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
    var authorNode: String
    var deleted: Bool

    init(id: String, name: String, spec: String, hlc: String, deleted: Bool) {
        self.id = id
        self.name = name
        self.spec = spec
        self.hlc = hlc
        self.authorNode = HybridLogicalClock.decode(hlc)?.node ?? ""
        self.deleted = deleted
    }
}

/// Which version of each other device's file we have already merged.
///
/// Lets a sync skip a file that has not changed, instead of re-downloading every
/// device's whole backup on every pass.
@Model
final class RemoteVersion {
    @Attribute(.unique) var fileName: String
    var version: String

    init(fileName: String, version: String) {
        self.fileName = fileName
        self.version = version
    }
}

/// Sync bookkeeping. One row.
@Model
final class SyncMeta {
    @Attribute(.unique) var singleton: String = "meta"
    /// Newest clock we had when our own file was last uploaded successfully.
    var lastUploadedHlc: String?
    var lastSyncedAt: Date?
    /// Which storage provider the notes currently belong to.
    var connectedProvider: String?

    init() {}
}
