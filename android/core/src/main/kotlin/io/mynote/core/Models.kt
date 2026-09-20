package io.mynote.core

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonPrimitive

val MyNoteJson = Json {
    ignoreUnknownKeys = true      // an older client must survive a newer server
    encodeDefaults = true
    explicitNulls = true
}

@Serializable
enum class Entity {
    @SerialName("note") NOTE,
    @SerialName("block") BLOCK,
    @SerialName("theme") THEME,
    @SerialName("attachment") ATTACHMENT;

    val wire: String
        get() = name.lowercase()
}

/**
 * One record change on the wire. Field names match the server's column names
 * exactly so neither side needs a translation table.
 */
@Serializable
data class Change(
    val entity: Entity,
    val id: String,
    val hlc: String,
    val deleted: Boolean = false,
    val serverSeq: Int? = null,
    val fields: Map<String, JsonElement> = emptyMap(),
) {
    val key: ChangeKey get() = ChangeKey(entity, id)

    fun string(name: String): String? =
        (fields[name] as? JsonPrimitive)?.takeIf { it !is JsonNull }?.contentOrNull

    fun int(name: String): Int? = (fields[name] as? JsonPrimitive)?.intOrNull
}

data class ChangeKey(val entity: Entity, val id: String)

@Serializable
data class SyncRequest(
    val cursor: Int,
    val changes: List<Change>,
    val limit: Int? = null,
)

@Serializable
data class Rejection(val entity: Entity, val id: String, val reason: String)

@Serializable
data class SyncResponse(
    val cursor: Int,
    val changes: List<Change>,
    val hasMore: Boolean,
    val serverTime: Long,
    val rejected: List<Rejection> = emptyList(),
)

@Serializable
enum class BlockType {
    @SerialName("paragraph") PARAGRAPH,
    @SerialName("heading1") HEADING1,
    @SerialName("heading2") HEADING2,
    @SerialName("heading3") HEADING3,
    @SerialName("todo") TODO_ITEM,
    @SerialName("bullet") BULLET,
    @SerialName("numbered") NUMBERED,
    @SerialName("quote") QUOTE,
    @SerialName("code") CODE,
    @SerialName("divider") DIVIDER,
    @SerialName("image") IMAGE;

    val wire: String
        get() = when (this) {
            TODO_ITEM -> "todo"
            else -> name.lowercase()
        }

    /**
     * Whether pressing Return keeps this type for the new block.
     *
     * Lists continue; a heading does not, because the line after a heading is
     * almost never another heading.
     */
    val continuesOnSplit: Boolean
        get() = this == TODO_ITEM || this == BULLET || this == NUMBERED

    companion object {
        fun fromWire(value: String): BlockType? =
            entries.firstOrNull { it.wire == value }
    }
}

/** The editable payload of a block; schema'd rather than free-form JSON. */
@Serializable
data class BlockContent(
    val text: String = "",
    val checked: Boolean? = null,
    val language: String? = null,
    val attachmentId: String? = null,
    /**
     * Inline formatting over [text], in UTF-16 offsets. See [InlineSpans].
     *
     * Absent when there is none, so a client built before inline formatting
     * existed reads the block, ignores the field it does not know, and still
     * shows the right words. It would drop the formatting on its next write,
     * which is the accepted cost of having no server to coordinate a rollout.
     */
    val spans: List<Span>? = null,
) {
    fun encoded(): String = MyNoteJson.encodeToString(serializer(), this)

    /** Formatting, normalised against the current text. */
    val inlineSpans: List<Span>
        get() = InlineSpans.normalized(spans ?: emptyList(), text.length)

    fun withSpans(updated: List<Span>): BlockContent =
        copy(spans = updated.ifEmpty { null })

    companion object {
        fun decode(raw: String): BlockContent =
            runCatching { MyNoteJson.decodeFromString(serializer(), raw) }
                .getOrElse { BlockContent() }
    }
}

data class Note(
    val id: String,
    val title: String = "",
    val icon: String? = null,
    val parentId: String? = null,
    val orderKey: String,
    val hlc: String,
    val deleted: Boolean = false,
)

data class Block(
    val id: String,
    val noteId: String,
    val parentId: String? = null,
    val orderKey: String,
    val type: BlockType = BlockType.PARAGRAPH,
    val content: BlockContent = BlockContent(),
    val hlc: String,
    val deleted: Boolean = false,
)

// ---- wire conversion -------------------------------------------------------

private fun str(value: String?): JsonElement =
    if (value == null) JsonNull else JsonPrimitive(value)

fun Note.asChange(): Change = Change(
    entity = Entity.NOTE,
    id = id,
    hlc = hlc,
    deleted = deleted,
    fields = mapOf(
        "title" to JsonPrimitive(title),
        "icon" to str(icon),
        "parent_id" to str(parentId),
        "order_key" to JsonPrimitive(orderKey),
    ),
)

fun Change.toNote(): Note? {
    if (entity != Entity.NOTE) return null
    val orderKey = string("order_key") ?: return null
    return Note(
        id = id,
        title = string("title") ?: "",
        icon = string("icon"),
        parentId = string("parent_id"),
        orderKey = orderKey,
        hlc = hlc,
        deleted = deleted,
    )
}

fun Block.asChange(): Change = Change(
    entity = Entity.BLOCK,
    id = id,
    hlc = hlc,
    deleted = deleted,
    fields = mapOf(
        "note_id" to JsonPrimitive(noteId),
        "parent_id" to str(parentId),
        "order_key" to JsonPrimitive(orderKey),
        "type" to JsonPrimitive(type.wire),
        "content" to JsonPrimitive(content.encoded()),
    ),
)

fun Change.toBlock(): Block? {
    if (entity != Entity.BLOCK) return null
    val noteId = string("note_id") ?: return null
    val orderKey = string("order_key") ?: return null
    val type = BlockType.fromWire(string("type") ?: "") ?: return null
    return Block(
        id = id,
        noteId = noteId,
        parentId = string("parent_id"),
        orderKey = orderKey,
        type = type,
        content = BlockContent.decode(string("content") ?: "{}"),
        hlc = hlc,
        deleted = deleted,
    )
}
