package io.mynote.app.sync

import io.mynote.app.data.MyNoteDatabase
import io.mynote.core.Block
import io.mynote.core.BlockContent
import io.mynote.core.BlockType
import io.mynote.core.Change
import io.mynote.core.Entity
import io.mynote.core.FractionalIndex
import io.mynote.core.InlineSpans
import io.mynote.core.Note
import io.mynote.core.WelcomeNote
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

    /**
     * Return pressed: the text before the caret stays, the rest becomes a new
     * block underneath.
     *
     * @return the id of the new block, so the caller can move the caret into it.
     */
    suspend fun splitBlock(
        block: Block,
        before: String,
        after: String,
        nextOrderKey: String?,
    ): String {
        // Formatting goes with the words. The offsets come from the original
        // text rather than from `before` and `after` alone, because a Return
        // pressed over a selection deletes the middle — so the tail does not
        // start where the head ends.
        val originalText = block.content.text
        val originalSpans = block.content.inlineSpans
        val tailStart = originalText.length - after.length

        update(
            block.copy(
                content = block.content.copy(text = before)
                    .withSpans(InlineSpans.slice(originalSpans, originalText.length, 0, before.length))
            )
        )

        val tail = Block(
            id = UUID.randomUUID().toString(),
            noteId = block.noteId,
            orderKey = FractionalIndex.between(block.orderKey, nextOrderKey),
            // A list carries on as a list; a heading does not, because the line
            // after a heading is almost never another heading.
            type = if (block.type.continuesOnSplit) block.type else BlockType.PARAGRAPH,
            content = BlockContent(text = after).withSpans(
                InlineSpans.slice(originalSpans, originalText.length, tailStart, originalText.length)
            ),
            hlc = coordinator.engine.stamp(),
        )
        write(tail.asChange())
        return tail.id
    }

    /**
     * Backspace at the start of a block: fold it into the one above.
     *
     * @return the caret offset in the previous block, i.e. the join point.
     */
    suspend fun mergeIntoPrevious(block: Block, previous: Block): Int {
        val joinOffset = previous.content.text.length

        if (block.content.text.isNotEmpty()) {
            val joined = previous.content.text + block.content.text
            update(
                previous.copy(
                    content = previous.content.copy(text = joined).withSpans(
                        InlineSpans.concatenated(
                            previous.content.inlineSpans, previous.content.text.length,
                            block.content.inlineSpans, block.content.text.length,
                        )
                    )
                )
            )
        }
        deleteBlock(block.id)
        return joinOffset
    }

    /**
     * Create the welcome note. The caller decides whether it is wanted; this
     * only knows how to write it.
     */
    suspend fun seedWelcomeNote(backupAvailable: Boolean): String {
        val noteId = createNote(title = WelcomeNote.TITLE)

        // createNote leaves one empty block for the cursor; the first line takes
        // it over rather than sitting under a blank.
        val firstBlockId = db.blocks().idsForNote(noteId).firstOrNull()
        var previousKey: String? = null

        WelcomeNote.lines(backupAvailable).forEachIndexed { index, line ->
            val orderKey = FractionalIndex.between(previousKey, null)
            val block = Block(
                id = if (index == 0 && firstBlockId != null) firstBlockId else UUID.randomUUID().toString(),
                noteId = noteId,
                orderKey = orderKey,
                type = line.type,
                content = BlockContent(text = line.text),
                hlc = coordinator.engine.stamp(),
            )
            write(block.asChange())
            previousKey = orderKey
        }
        return noteId
    }

    suspend fun update(block: Block) {
        write(block.copy(hlc = coordinator.engine.stamp()).asChange())
    }

    /**
     * Change one block's type, leaving its text alone.
     *
     * The row is re-read here rather than taken from the caller. A caller holds
     * a snapshot from the last time the screen composed, and a block is written
     * whole — so when the formatting bar is tapped a keystroke's write may still
     * be in flight, and a whole-row write built on that snapshot puts the older
     * text back under a newer clock. The character is then gone locally and in
     * the backup. Launches on the same dispatcher run in order, so by the time
     * this reads, the keystroke has landed.
     */
    suspend fun setBlockType(blockId: String, type: BlockType) {
        val current = blockById(blockId) ?: return
        update(current.copy(type = type))
    }

    /** The stored row as the domain type, read fresh. */
    suspend fun blockById(blockId: String): Block? {
        val row = db.blocks().byId(blockId) ?: return null
        val blockType = BlockType.fromWire(row.type) ?: return null
        return Block(
            id = row.id,
            noteId = row.noteId,
            parentId = row.parentId,
            orderKey = row.orderKey,
            type = blockType,
            content = BlockContent.decode(row.content),
            hlc = row.hlc,
            deleted = row.deleted,
        )
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
        coordinator.engine.record(change)
        coordinator.refreshPending()
        coordinator.scheduleSync()
    }
}
