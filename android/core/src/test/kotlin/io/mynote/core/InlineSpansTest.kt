package io.mynote.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Inline formatting.
 *
 * Every case here exists in `InlineSpansTests.swift` as well, with the same
 * inputs and the same expected output. They are the only thing keeping the two
 * implementations agreeing on what a note looks like, because nothing at build
 * time checks one against the other.
 */
class InlineSpansTest {

    // region Normalising

    @Test
    fun `adjacent runs with the same formatting become one`() {
        val spans = listOf(
            Span.of(0, 3, listOf(Mark.BOLD)),
            Span.of(3, 3, listOf(Mark.BOLD)),
        )
        assertEquals(
            listOf(Span.of(0, 6, listOf(Mark.BOLD))),
            InlineSpans.normalized(spans, 10),
        )
    }

    @Test
    fun `a run past the end of the text is clipped to it`() {
        val spans = listOf(Span.of(2, 50, listOf(Mark.ITALIC)))
        assertEquals(
            listOf(Span.of(2, 3, listOf(Mark.ITALIC))),
            InlineSpans.normalized(spans, 5),
        )
    }

    @Test
    fun `overlapping runs merge their marks`() {
        val spans = listOf(
            Span.of(0, 4, listOf(Mark.BOLD)),
            Span.of(2, 4, listOf(Mark.ITALIC)),
        )
        assertEquals(
            listOf(
                Span.of(0, 2, listOf(Mark.BOLD)),
                Span.of(2, 2, listOf(Mark.BOLD, Mark.ITALIC)),
                Span.of(4, 2, listOf(Mark.ITALIC)),
            ),
            InlineSpans.normalized(spans, 6),
        )
    }

    @Test
    fun `marks are stored in a fixed order whatever order they arrive in`() {
        val span = Span.of(0, 1, listOf(Mark.STRIKETHROUGH, Mark.BOLD, Mark.ITALIC))
        assertEquals(listOf(Mark.BOLD, Mark.ITALIC, Mark.STRIKETHROUGH), span.marks)
    }

    // endregion

    // region Toggling

    @Test
    fun `toggling a mark on a plain range sets it`() {
        assertEquals(
            listOf(Span.of(0, 4, listOf(Mark.BOLD))),
            InlineSpans.toggle(Mark.BOLD, 0, 4, emptyList(), 10),
        )
    }

    @Test
    fun `toggling a mark the whole range already has removes it`() {
        val spans = listOf(Span.of(0, 4, listOf(Mark.BOLD)))
        assertTrue(InlineSpans.toggle(Mark.BOLD, 0, 4, spans, 10).isEmpty())
    }

    @Test
    fun `toggling a partly-marked range sets the whole of it`() {
        val spans = listOf(Span.of(0, 2, listOf(Mark.BOLD)))
        assertEquals(
            listOf(Span.of(0, 4, listOf(Mark.BOLD))),
            InlineSpans.toggle(Mark.BOLD, 0, 4, spans, 10),
        )
    }

    @Test
    fun `toggling one mark leaves the others alone`() {
        val spans = listOf(Span.of(0, 4, listOf(Mark.BOLD, Mark.ITALIC)))
        assertEquals(
            listOf(Span.of(0, 4, listOf(Mark.ITALIC))),
            InlineSpans.toggle(Mark.BOLD, 0, 4, spans, 10),
        )
    }

    // endregion

    // region Reading

    @Test
    fun `a toolbar shows a mark active only when the whole selection has it`() {
        val spans = listOf(Span.of(0, 2, listOf(Mark.BOLD)))
        assertEquals(setOf(Mark.BOLD), InlineSpans.marks(0, 2, spans, 6))
        assertEquals(emptySet<Mark>(), InlineSpans.marks(0, 4, spans, 6))
    }

    @Test
    fun `an empty selection inherits from the character before it`() {
        val spans = listOf(Span.of(0, 3, listOf(Mark.BOLD)))
        // Caret just after the bold run: typing continues bold.
        assertEquals(setOf(Mark.BOLD), InlineSpans.marks(3, 3, spans, 6))
        // Caret at the very start: nothing to inherit, so typing is plain.
        assertEquals(emptySet<Mark>(), InlineSpans.marks(0, 0, spans, 6))
    }

    // endregion

    // region Following an edit

    @Test
    fun `text inserted after a run continues its formatting`() {
        val spans = listOf(Span.of(0, 4, listOf(Mark.BOLD)))
        assertEquals(
            listOf(Span.of(0, 7, listOf(Mark.BOLD))),
            InlineSpans.adjusted(spans, 4, 4, 4, 3),
        )
    }

    @Test
    fun `text inserted before a run does not take its formatting`() {
        val spans = listOf(Span.of(0, 4, listOf(Mark.BOLD)))
        assertEquals(
            listOf(Span.of(2, 4, listOf(Mark.BOLD))),
            InlineSpans.adjusted(spans, 4, 0, 0, 2),
        )
    }

    @Test
    fun `deleting inside a run shortens it`() {
        val spans = listOf(Span.of(2, 6, listOf(Mark.ITALIC)))
        assertEquals(
            listOf(Span.of(2, 4, listOf(Mark.ITALIC))),
            InlineSpans.adjusted(spans, 10, 3, 5, 0),
        )
    }

    @Test
    fun `deleting a whole run removes it`() {
        val spans = listOf(Span.of(0, 4, listOf(Mark.BOLD)))
        assertTrue(InlineSpans.adjusted(spans, 8, 0, 4, 0).isEmpty())
    }

    // endregion

    // region Moving text between blocks

    @Test
    fun `splitting carries each half's formatting with it`() {
        // "boldplain" with the first four units bold, split after four.
        val spans = listOf(Span.of(0, 4, listOf(Mark.BOLD)))
        assertEquals(
            listOf(Span.of(0, 4, listOf(Mark.BOLD))),
            InlineSpans.slice(spans, 9, 0, 4),
        )
        assertTrue(InlineSpans.slice(spans, 9, 4, 9).isEmpty())
    }

    @Test
    fun `a slice from the middle is rebased to zero`() {
        val spans = listOf(Span.of(4, 3, listOf(Mark.UNDERLINE)))
        assertEquals(
            listOf(Span.of(1, 3, listOf(Mark.UNDERLINE))),
            InlineSpans.slice(spans, 10, 3, 8),
        )
    }

    @Test
    fun `merging two blocks shifts the second block's formatting along`() {
        val first = listOf(Span.of(0, 2, listOf(Mark.BOLD)))
        val second = listOf(Span.of(1, 2, listOf(Mark.ITALIC)))
        assertEquals(
            listOf(
                Span.of(0, 2, listOf(Mark.BOLD)),
                Span.of(6, 2, listOf(Mark.ITALIC)),
            ),
            InlineSpans.concatenated(first, 5, second, 4),
        )
    }

    // endregion

    // region Links

    @Test
    fun `a link is reported only when it covers the whole range`() {
        val spans = listOf(Span.of(0, 4, emptyList(), "https://example.com"))
        assertEquals("https://example.com", InlineSpans.link(0, 4, spans, 10))
        assertNull(InlineSpans.link(0, 6, spans, 10))
    }

    @Test
    fun `clearing a link leaves the marks in place`() {
        val spans = listOf(Span.of(0, 4, listOf(Mark.BOLD), "https://example.com"))
        assertEquals(
            listOf(Span.of(0, 4, listOf(Mark.BOLD))),
            InlineSpans.setLink(null, 0, 4, spans, 4),
        )
    }

    // endregion

    // region The wire format

    @Test
    fun `a block written before inline formatting existed still reads`() {
        val legacy = """{"text":"hello","checked":null,"language":null,"attachmentId":null}"""
        val content = BlockContent.decode(legacy)
        assertEquals("hello", content.text)
        assertNull(content.spans)
        assertTrue(content.inlineSpans.isEmpty())
    }

    @Test
    fun `formatting survives a round trip through the wire format`() {
        val spans = listOf(Span.of(0, 5, listOf(Mark.BOLD, Mark.ITALIC), "https://example.com"))
        val content = BlockContent(text = "hello world").withSpans(spans)

        val decoded = BlockContent.decode(content.encoded())
        assertEquals("hello world", decoded.text)
        assertEquals(spans, decoded.inlineSpans)
    }

    /**
     * The bytes iOS actually writes, pasted verbatim.
     *
     * The two encoders do not produce identical bytes and never have — Kotlin
     * writes its nulls out and orders keys differently, Swift escapes the
     * slashes in a URL. That is fine and predates this change. What must hold
     * is that each side can read the other's file, so both fixtures are pinned
     * here and in `InlineSpansTests.swift`.
     */
    @Test
    fun `a block written by iOS reads correctly`() {
        val fromSwift =
            """{"text":"hello world","spans":[{"start":0,"length":5,"link":"https:\/\/example.com","marks":["bold","italic"]}]}"""
        val content = BlockContent.decode(fromSwift)
        assertEquals("hello world", content.text)
        assertEquals(
            listOf(Span.of(0, 5, listOf(Mark.BOLD, Mark.ITALIC), "https://example.com")),
            content.inlineSpans,
        )
    }

    @Test
    fun `offsets are UTF-16 units, so an emoji counts as two`() {
        // "👋ab" — the wave is one character but two UTF-16 units, so bolding
        // just "a" is offset 2, not offset 1. Kotlin's String.length is already
        // UTF-16, which is why this side needs no conversion and Swift does.
        val text = "👋ab"
        assertEquals(4, text.length)

        val spans = InlineSpans.toggle(Mark.BOLD, 2, 3, emptyList(), text.length)
        assertEquals(listOf(Span.of(2, 1, listOf(Mark.BOLD))), spans)
    }

    // endregion

    // region Recovering an edit (Android)

    @Test
    fun `a character typed at the end is seen as an insertion there`() {
        val edit = InlineSpans.editBetween("hello", "hellox")
        assertEquals(InlineSpans.Edit(5, 5, 1), edit)
    }

    @Test
    fun `a character typed in the middle is located exactly`() {
        val edit = InlineSpans.editBetween("hello", "helXlo")
        assertEquals(InlineSpans.Edit(3, 3, 1), edit)
    }

    @Test
    fun `a deletion is seen as a replacement by nothing`() {
        val edit = InlineSpans.editBetween("hello", "helo")
        assertEquals(InlineSpans.Edit(3, 4, 0), edit)
    }

    @Test
    fun `replacing a selection is one edit`() {
        val edit = InlineSpans.editBetween("hello world", "hello there")
        assertEquals(InlineSpans.Edit(6, 11, 5), edit)
    }

    @Test
    fun `no change is no edit`() {
        assertEquals(InlineSpans.Edit(5, 5, 0), InlineSpans.editBetween("hello", "hello"))
    }

    @Test
    fun `typing at the end of a bold word keeps it bold, via the diff`() {
        val spans = listOf(Span.of(0, 5, listOf(Mark.BOLD)))
        assertEquals(
            listOf(Span.of(0, 6, listOf(Mark.BOLD))),
            InlineSpans.adjustedForEdit(spans, "hello", "hellox"),
        )
    }

    @Test
    fun `typing before a bold word leaves it plain, via the diff`() {
        val spans = listOf(Span.of(0, 5, listOf(Mark.BOLD)))
        assertEquals(
            listOf(Span.of(1, 5, listOf(Mark.BOLD))),
            InlineSpans.adjustedForEdit(spans, "hello", "xhello"),
        )
    }

    // endregion
}
