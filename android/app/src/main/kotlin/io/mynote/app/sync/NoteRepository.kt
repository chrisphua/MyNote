package io.mynote.app.sync

import io.mynote.app.data.MyNoteDatabase
import io.mynote.core.Block
import io.mynote.core.BlockType
import io.mynote.core.Change
import io.mynote.core.Entity
import io.mynote.core.FractionalIndex
import io.mynote.core.Note
import io.mynote.core.ThemeSpec
import io.mynote.core.asChange
import kotlinx.serialization.json.JsonPrimitive
import java.util.UUID

/**
 * Every write the UI makes goes through here.
 *
 * One job: stamp the edit with a fresh clock, persist it locally, queue it for
 * sync, and return — without awaiting the network. Callers treat these as
 * instant, because locally they are.
 */
class NoteRepository(
    private val db: MyNoteDatabase,
    private val coordinator: SyncCoordinator,
) {
    suspend fun createNote(title: String = "", parentId: String? = null, after: String? = null): String {
        val id = UUID.randomUUID().toString()
        write(
            Note(
                id = id,
                title = title,
                parentId = parentId,
                orderKey = FractionalIndex.between(after, null),
                hlc = coordinator.engine.stamp(),
            ).asChange()
        )
        // A new page opens with one empty paragraph, so the cursor has somewhere
        // to land instead of an empty screen.
        appendBlock(id, null)
        return id
    }

    suspend fun rename(noteId: String, title: String, icon: String?, parentId: String?, orderKey: String) {
        write(Note(noteId, title, icon, parentId, orderKey, coordinator.engine.stamp()).asChange())
    }

    suspend fun deleteNote(noteId: String) {
        val blockIds = db.blocks().idsForNote(noteId)
        write(Change(Entity.NOTE, noteId, coordinator.engine.stamp(), deleted = true))
        // Tombstone the blocks too, or they would linger on other devices.
        for (blockId in blockIds) {
            write(Change(Entity.BLOCK, blockId, coordinator.engine.stamp(), deleted = true))
        }
    }

    suspend fun appendBlock(
        noteId: String,
        after: String?,
        before: String? = null,
        type: BlockType = BlockType.PARAGRAPH,
    ): String {
        val block = Block(
            id = UUID.randomUUID().toString(),
            noteId = noteId,
            orderKey = FractionalIndex.between(after, before),
            type = type,
            hlc = coordinator.engine.stamp(),
        )
        write(block.asChange())
        return block.id
    }

    suspend fun update(block: Block) {
        write(block.copy(hlc = coordinator.engine.stamp()).asChange())
    }

    suspend fun deleteBlock(blockId: String) {
        write(Change(Entity.BLOCK, blockId, coordinator.engine.stamp(), deleted = true))
    }

    suspend fun saveTheme(spec: ThemeSpec) {
        write(
            Change(
                entity = Entity.THEME,
                id = spec.id,
                hlc = coordinator.engine.stamp(),
                fields = mapOf(
                    "name" to JsonPrimitive(spec.name),
                    "spec" to JsonPrimitive(spec.encoded()),
                ),
            )
        )
    }

    private suspend fun write(change: Change) {
        coordinator.engine.enqueue(change)
        coordinator.scheduleSync()
    }
}
