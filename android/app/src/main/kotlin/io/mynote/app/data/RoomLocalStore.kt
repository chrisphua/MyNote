package io.mynote.app.data

import androidx.room.withTransaction
import io.mynote.core.Block
import io.mynote.core.BlockContent
import io.mynote.core.BlockType
import io.mynote.core.Change
import io.mynote.core.Entity
import io.mynote.core.Hlc
import io.mynote.core.LocalStore
import io.mynote.core.Note
import io.mynote.core.ThemeSpec
import io.mynote.core.asChange
import io.mynote.core.toBlock
import io.mynote.core.toNote
import kotlinx.serialization.json.JsonPrimitive

/**
 * [LocalStore] backed by Room.
 *
 * This database is the source of truth. The file in the user's Drive is a
 * projection of it, so a failed upload delays a backup but can never lose an
 * edit — which is why there is no outbox here.
 */
class RoomLocalStore(private val db: MyNoteDatabase) : LocalStore {

    override suspend fun changesAuthoredBy(node: String): List<Change> = buildList {
        db.notes().authoredBy(node).forEach { row ->
            add(
                Note(row.id, row.title, row.icon, row.parentId, row.orderKey, row.hlc, row.deleted)
                    .asChange()
            )
        }
        db.blocks().authoredBy(node).forEach { row ->
            val type = BlockType.fromWire(row.type) ?: return@forEach
            add(
                Block(
                    id = row.id, noteId = row.noteId, parentId = row.parentId,
                    orderKey = row.orderKey, type = type,
                    content = BlockContent.decode(row.content),
                    hlc = row.hlc, deleted = row.deleted,
                ).asChange()
            )
        }
        db.themes().authoredBy(node).forEach { row ->
            add(
                Change(
                    entity = Entity.THEME, id = row.id, hlc = row.hlc, deleted = row.deleted,
                    fields = mapOf(
                        "name" to JsonPrimitive(row.name),
                        "spec" to JsonPrimitive(row.spec),
                    ),
                )
            )
        }
    }

    override suspend fun recordLocal(change: Change) = writeRecord(change)

    override suspend fun applyRemote(change: Change) = writeRecord(change)

    override suspend fun currentHlc(entity: Entity, id: String): String? = when (entity) {
        Entity.NOTE -> db.notes().hlc(id)
        Entity.BLOCK -> db.blocks().hlc(id)
        Entity.THEME -> db.themes().hlc(id)
        Entity.ATTACHMENT -> null   // attachments carry no local row yet
    }

    override suspend fun mergedVersions(): Map<String, String> =
        db.remoteVersions().all().associate { it.fileName to it.version }

    override suspend fun setMergedVersion(file: String, version: String) {
        db.remoteVersions().put(RemoteVersionRow(file, version))
    }

    override suspend fun lastUploadedHlc(): String? = meta().lastUploadedHlc

    override suspend fun setLastUploadedHlc(hlc: String) {
        db.syncMeta().put(
            meta().copy(lastUploadedHlc = hlc, lastSyncedAt = System.currentTimeMillis())
        )
    }

    override suspend fun newestHlc(): String? = listOfNotNull(
        db.notes().maxHlc(),
        db.blocks().maxHlc(),
        db.themes().maxHlc(),
    ).maxOrNull()

    override suspend fun clearAll() {
        // Records carry no account. Connecting a different folder without this
        // would upload one person's notes into another's Drive.
        db.clearAllTables()
    }

    // ---- app-facing helpers -------------------------------------------------

    suspend fun lastSyncedAt(): Long? = meta().lastSyncedAt

    suspend fun connectedProvider(): String? = meta().connectedProvider

    suspend fun setConnectedProvider(provider: String?) {
        db.syncMeta().put(meta().copy(connectedProvider = provider))
    }

    /** Custom themes that arrived from another device. */
    suspend fun syncedThemes(): List<ThemeSpec> =
        db.themes().allActive().mapNotNull { ThemeSpec.decode(it.spec)?.sanitized() }

    private suspend fun meta(): SyncMetaRow = db.syncMeta().get() ?: SyncMetaRow()

    // ---- writing ------------------------------------------------------------

    private suspend fun writeRecord(change: Change): Unit = db.withTransaction {
        val author = Hlc.decode(change.hlc)?.node.orEmpty()

        when (change.entity) {
            Entity.NOTE -> {
                val existing = db.notes().byId(change.id)
                val row = when {
                    change.deleted && existing != null ->
                        existing.copy(hlc = change.hlc, authorNode = author, deleted = true,
                                      updatedAt = System.currentTimeMillis())
                    change.deleted ->
                        // Tombstone for a note we never had: record it so a later
                        // merge cannot resurrect the delete.
                        NoteRow(id = change.id, orderKey = "", hlc = change.hlc,
                                authorNode = author, deleted = true)
                    else -> change.toNote()?.let {
                        NoteRow(it.id, it.title, it.icon, it.parentId, it.orderKey,
                                it.hlc, author, false)
                    }
                }
                row?.let { db.notes().upsert(it) }
            }

            Entity.BLOCK -> {
                val existing = db.blocks().byId(change.id)
                val row = when {
                    change.deleted && existing != null ->
                        existing.copy(hlc = change.hlc, authorNode = author, deleted = true,
                                      updatedAt = System.currentTimeMillis())
                    change.deleted ->
                        BlockRow(id = change.id, noteId = "", orderKey = "", type = "paragraph",
                                 content = "{}", hlc = change.hlc, authorNode = author, deleted = true)
                    else -> change.toBlock()?.let {
                        BlockRow(it.id, it.noteId, it.parentId, it.orderKey, it.type.wire,
                                 it.content.encoded(), it.hlc, author, false)
                    }
                }
                row?.let { db.blocks().upsert(it) }
            }

            Entity.THEME -> db.themes().upsert(
                ThemeRow(
                    id = change.id,
                    name = change.string("name") ?: "Theme",
                    spec = change.string("spec") ?: "{}",
                    hlc = change.hlc,
                    authorNode = author,
                    deleted = change.deleted,
                )
            )

            Entity.ATTACHMENT -> Unit
        }
    }
}
