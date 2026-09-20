import Foundation

public enum Entity: String, Codable, Sendable, CaseIterable {
    case note, block, theme, attachment
}

/// One record change on the wire. Field names match the server's column names
/// exactly so neither side needs a translation table.
public struct Change: Codable, Equatable, Sendable {
    public var entity: Entity
    public var id: String
    public var hlc: String
    public var deleted: Bool
    public var serverSeq: Int?
    public var fields: [String: JSONValue]

    public init(entity: Entity, id: String, hlc: String, deleted: Bool = false,
                serverSeq: Int? = nil, fields: [String: JSONValue] = [:]) {
        self.entity = entity
        self.id = id
        self.hlc = hlc
        self.deleted = deleted
        self.serverSeq = serverSeq
        self.fields = fields
    }
}

public struct SyncRequest: Codable, Sendable {
    public var cursor: Int
    public var changes: [Change]
    public var limit: Int?
}

public struct Rejection: Codable, Equatable, Sendable {
    public var entity: Entity
    public var id: String
    public var reason: String
}

public struct SyncResponse: Codable, Sendable {
    public var cursor: Int
    public var changes: [Change]
    public var hasMore: Bool
    public var serverTime: Int64
    public var rejected: [Rejection]
}

public enum BlockType: String, Codable, Sendable, CaseIterable {
    case paragraph, heading1, heading2, heading3
    case todo, bullet, numbered, quote, code, divider, image

    /// Whether pressing Return keeps this type for the new block.
    ///
    /// Lists continue; a heading does not, because the line after a heading is
    /// almost never another heading.
    public var continuesOnSplit: Bool {
        switch self {
        case .todo, .bullet, .numbered: true
        default: false
        }
    }
}

public struct Note: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var icon: String?
    public var parentId: String?
    public var orderKey: String
    public var hlc: String
    public var deleted: Bool

    public init(id: String = UUID().uuidString, title: String = "", icon: String? = nil,
                parentId: String? = nil, orderKey: String, hlc: String, deleted: Bool = false) {
        self.id = id
        self.title = title
        self.icon = icon
        self.parentId = parentId
        self.orderKey = orderKey
        self.hlc = hlc
        self.deleted = deleted
    }
}

/// The editable payload of a block. Kept as its own Codable type so the JSON we
/// store in `blocks.content` is schema'd rather than free-form.
public struct BlockContent: Codable, Equatable, Sendable {
    public var text: String
    public var checked: Bool?
    public var language: String?
    public var attachmentId: String?
    /// Inline formatting over `text`, in UTF-16 offsets. See `InlineSpans`.
    ///
    /// Optional, and absent when there is none — so a client built before
    /// inline formatting existed reads the block, ignores the field it does not
    /// know, and still shows the right words. It would drop the formatting on
    /// its next write, which is the accepted cost of having no server to
    /// coordinate a rollout.
    public var spans: [Span]?

    public init(text: String = "", checked: Bool? = nil,
                language: String? = nil, attachmentId: String? = nil,
                spans: [Span]? = nil) {
        self.text = text
        self.checked = checked
        self.language = language
        self.attachmentId = attachmentId
        self.spans = spans
    }

    /// Formatting, normalised against the current text.
    public var inlineSpans: [Span] {
        get { InlineSpans.normalized(spans ?? [], textLength: text.utf16.count) }
        set { spans = newValue.isEmpty ? nil : newValue }
    }

    public func encoded() -> String {
        guard let data = try? JSONEncoder().encode(self),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    public static func decode(_ raw: String) -> BlockContent {
        guard let data = raw.data(using: .utf8),
              let value = try? JSONDecoder().decode(BlockContent.self, from: data)
        else { return BlockContent() }
        return value
    }
}

public struct Block: Identifiable, Equatable, Sendable {
    public var id: String
    public var noteId: String
    public var parentId: String?
    public var orderKey: String
    public var type: BlockType
    public var content: BlockContent
    public var hlc: String
    public var deleted: Bool

    public init(id: String = UUID().uuidString, noteId: String, parentId: String? = nil,
                orderKey: String, type: BlockType = .paragraph,
                content: BlockContent = BlockContent(), hlc: String, deleted: Bool = false) {
        self.id = id
        self.noteId = noteId
        self.parentId = parentId
        self.orderKey = orderKey
        self.type = type
        self.content = content
        self.hlc = hlc
        self.deleted = deleted
    }
}

// MARK: - Wire conversion

public extension Note {
    func asChange() -> Change {
        Change(entity: .note, id: id, hlc: hlc, deleted: deleted, fields: [
            "title": .string(title),
            "icon": icon.map(JSONValue.string) ?? .null,
            "parent_id": parentId.map(JSONValue.string) ?? .null,
            "order_key": .string(orderKey),
        ])
    }

    init?(change: Change) {
        guard change.entity == .note, let orderKey = change.fields.string("order_key") else { return nil }
        self.init(
            id: change.id,
            title: change.fields.string("title") ?? "",
            icon: change.fields.string("icon"),
            parentId: change.fields.string("parent_id"),
            orderKey: orderKey,
            hlc: change.hlc,
            deleted: change.deleted
        )
    }
}

public extension Block {
    func asChange() -> Change {
        Change(entity: .block, id: id, hlc: hlc, deleted: deleted, fields: [
            "note_id": .string(noteId),
            "parent_id": parentId.map(JSONValue.string) ?? .null,
            "order_key": .string(orderKey),
            "type": .string(type.rawValue),
            "content": .string(content.encoded()),
        ])
    }

    init?(change: Change) {
        guard change.entity == .block,
              let noteId = change.fields.string("note_id"),
              let orderKey = change.fields.string("order_key"),
              let rawType = change.fields.string("type"),
              let type = BlockType(rawValue: rawType)
        else { return nil }
        self.init(
            id: change.id,
            noteId: noteId,
            parentId: change.fields.string("parent_id"),
            orderKey: orderKey,
            type: type,
            content: BlockContent.decode(change.fields.string("content") ?? "{}"),
            hlc: change.hlc,
            deleted: change.deleted
        )
    }
}
