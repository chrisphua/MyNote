package io.mynote.core

import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The JSON on the wire is the contract between three codebases. These assert the
 * exact shape the Worker validates in `backend/src/sync.ts`, so a rename on one
 * side fails here rather than in production.
 */
class WireFormatTest {

    @Test
    fun `a block change serialises to the columns the server expects`() {
        val block = Block(
            id = "b1",
            noteId = "n1",
            orderKey = "a0",
            type = BlockType.HEADING2,
            content = BlockContent(text = "Hello"),
            hlc = "0000000000000064-0000-devA",
        )
        val json = MyNoteJson.encodeToString(Change.serializer(), block.asChange())

        assertTrue(json.contains("\"entity\":\"block\""))
        assertTrue(json.contains("\"note_id\""))
        assertTrue(json.contains("\"order_key\""))
        assertTrue(json.contains("\"heading2\""))
        // `content` is a JSON *string*, not a nested object — the server stores
        // it verbatim in a TEXT column and only checks that it parses.
        assertTrue(json.contains("\"content\":\"{"))
    }

    @Test
    fun `a to-do block uses the server's spelling, not Kotlin's`() {
        // TODO is a Kotlin keyword-ish name, so the enum constant differs from
        // the wire value. This is exactly where a silent mismatch would hide.
        assertEquals("todo", BlockType.TODO_ITEM.wire)
        assertEquals(BlockType.TODO_ITEM, BlockType.fromWire("todo"))
    }

    @Test
    fun `every block type round-trips through its wire value`() {
        for (type in BlockType.entries) {
            assertEquals(type, BlockType.fromWire(type.wire))
        }
    }

    @Test
    fun `a block change round-trips back into a block`() {
        val original = Block(
            id = "b1", noteId = "n1", orderKey = "a0",
            type = BlockType.CODE,
            content = BlockContent(text = "val x = 1", language = "kotlin"),
            hlc = "0000000000000064-0000-devA",
        )
        val restored = original.asChange().toBlock()
        assertEquals(original, restored)
    }

    @Test
    fun `a note change round-trips back into a note`() {
        val original = Note(
            id = "n1", title = "Trip", icon = "✈️", parentId = null,
            orderKey = "a0", hlc = "0000000000000064-0000-devA",
        )
        assertEquals(original, original.asChange().toNote())
    }

    @Test
    fun `a null parent survives the round trip as null, not the string null`() {
        val note = Note(id = "n1", orderKey = "a0", hlc = "h", parentId = null)
        val change = note.asChange()
        assertNull(change.string("parent_id"))
    }

    @Test
    fun `a server response decodes even with fields we do not know`() {
        // Forward compatibility: an older app must survive a newer server.
        val json = """
            {"cursor":7,"changes":[],"hasMore":false,"serverTime":123,
             "rejected":[],"somethingNew":{"a":1}}
        """.trimIndent()
        val decoded = MyNoteJson.decodeFromString(SyncResponse.serializer(), json)
        assertEquals(7, decoded.cursor)
    }

    @Test
    fun `a rejection decodes with the server's entity spelling`() {
        val json = """{"entity":"block","id":"b1","reason":"bad_block_type"}"""
        val decoded = MyNoteJson.decodeFromString(Rejection.serializer(), json)
        assertEquals(Entity.BLOCK, decoded.entity)
        assertNotNull(decoded.reason)
    }
}
