package io.mynote.app.data

import io.mynote.core.Change
import io.mynote.core.ChangeKey
import io.mynote.core.Entity
import io.mynote.core.LocalStore
import androidx.room.withTransaction
import io.mynote.core.MyNoteJson
import io.mynote.core.ThemeSpec
import io.mynote.core.toBlock
import io.mynote.core.toNote
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.JsonElement

private val FIELDS_SERIALIZER = MapSerializer(String.serializer(), JsonElement.serializer())

/** [LocalStore] backed by Room. */
class RoomLocalStore(private val db: MyNoteDatabase) : LocalStore {

    override suspend fun cursor(): Int = db.syncState().get()?.cursor ?: 0

    override suspend fun setCursor(value: Int) {
        db.syncState().put(SyncStateRow(cursor = value, lastSyncedAt = System.currentTimeMillis()))
    }

    override suspend fun outbox(limit: Int): List<Change> =
        db.outbox().oldest(limit).mapNotNull { it.toChange() }

    /**
     * One transaction, so the record and its outbox entry are never out of step.
     *
     * Process death between the two writes would otherwise leave the edit
     * visible locally with nothing queued to send it — it would simply never
     * sync, and nothing later would notice.
     */
    override suspend fun enqueue(change: Change) = db.withTransaction {
        writeRecord(change)

        val key = "${change.entity.wire}:${change.id}"
        val fields = MyNoteJson.encodeToString(FIELDS_SERIALIZER, change.fields)

        // Collapse a burst of keystrokes onto the existing row, preserving its
        // queue position, and only insert when there is nothing pending yet.
        val updated = db.outbox().updateExisting(key, change.hlc, change.deleted, fields)
        if (updated == 0) {
            db.outbox().insertIfAbsent(
                OutboxRow(
                    key = key,
                    entity = change.entity.wire,
                    recordId = change.id,
                    hlc = change.hlc,
                    deleted = change.deleted,
                    fieldsJson = fields,
                )
            )
        }
    }

    override suspend fun removeFromOutbox(sent: List<Change>) {
        if (sent.isEmpty()) return
        db.withTransaction {
            for (change in sent) {
                db.outbox().deleteConfirmed("${change.entity.wire}:${change.id}", change.hlc)
            }
        }
    }

    override suspend fun newestHlc(): String? = listOfNotNull(
        db.outbox().maxHlc(),
        db.notes().maxHlc(),
        db.blocks().maxHlc(),
        db.themes().maxHlc(),
    ).maxOrNull()

    override suspend fun clearAll() {
        // Local rows carry no uid, so switching accounts on one device must wipe
        // them: otherwise the previous account's queued edits get pushed into
        // the new account, and the new account inherits a cursor that makes its
        // own server rows unreachable.
        db.clearAllTables()
    }

    /**
     * Custom themes that arrived from another device.
     *
     * Themes sync like any other record, but the theme UI reads its own store,
     * so they have to be handed across explicitly at launch.
     */
    suspend fun syncedThemes(): List<ThemeSpec> =
        db.themes().allActive().mapNotNull { ThemeSpec.decode(it.spec)?.sanitized() }

    override suspend fun currentHlc(entity: Entity, id: String): String? = when (entity) {
        Entity.NOTE -> db.notes().hlc(id)
        Entity.BLOCK -> db.blocks().hlc(id)
        Entity.THEME -> db.themes().hlc(id)
        Entity.ATTACHMENT -> null   // attachments carry no local row yet
    }

    override suspend fun applyRemote(change: Change) = writeRecord(change)

    private suspend fun writeRecord(change: Change) {
        when (change.entity) {
            Entity.NOTE -> {
                val existing = db.notes().byId(change.id)
                val row = when {
                    change.deleted && existing != null ->
                        existing.copy(hlc = change.hlc, deleted = true, updatedAt = System.currentTimeMillis())
                    change.deleted ->
                        // Tombstone for a note we never had: record it so a later
                        // pull cannot resurrect the delete.
                        NoteRow(id = change.id, orderKey = "", hlc = change.hlc, deleted = true)
                    else -> change.toNote()?.let {
                        NoteRow(it.id, it.title, it.icon, it.parentId, it.orderKey, it.hlc, false)
                    }
                }
                row?.let { db.notes().upsert(it) }
            }

            Entity.BLOCK -> {
                val existing = db.blocks().byId(change.id)
                val row = when {
                    change.deleted && existing != null ->
                        existing.copy(hlc = change.hlc, deleted = true, updatedAt = System.currentTimeMillis())
                    change.deleted ->
                        BlockRow(id = change.id, noteId = "", orderKey = "", type = "paragraph",
                                 content = "{}", hlc = change.hlc, deleted = true)
                    else -> change.toBlock()?.let {
                        BlockRow(it.id, it.noteId, it.parentId, it.orderKey, it.type.wire,
                                 it.content.encoded(), it.hlc, false)
                    }
                }
                row?.let { db.blocks().upsert(it) }
            }

            Entity.THEME -> {
                db.themes().upsert(
                    ThemeRow(
                        id = change.id,
                        name = change.string("name") ?: "Theme",
                        spec = change.string("spec") ?: "{}",
                        hlc = change.hlc,
                        deleted = change.deleted,
                    )
                )
            }

            Entity.ATTACHMENT -> Unit
        }
    }

    private fun OutboxRow.toChange(): Change? {
        val parsed = io.mynote.core.Entity.entries.firstOrNull { it.wire == entity } ?: return null
        val fields = runCatching {
            MyNoteJson.decodeFromString(FIELDS_SERIALIZER, fieldsJson)
        }.getOrElse { emptyMap() }
        return Change(parsed, recordId, hlc, deleted, fields = fields)
    }
}
