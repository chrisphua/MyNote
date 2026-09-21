import Testing
import Foundation
@testable import MyNoteCore

/// Inline formatting.
///
/// Every case here exists in `InlineSpansTest.kt` as well, with the same inputs
/// and the same expected output. They are the only thing keeping the two
/// implementations agreeing on what a note looks like, because nothing at build
/// time checks one against the other.
@Suite("Inline spans")
struct InlineSpansTests {

    // MARK: - Normalising

    @Test("adjacent runs with the same formatting become one")
    func mergesAdjacent() {
        let spans = [
            Span(start: 0, length: 3, marks: [.bold]),
            Span(start: 3, length: 3, marks: [.bold]),
        ]
        #expect(InlineSpans.normalized(spans, textLength: 10) == [Span(start: 0, length: 6, marks: [.bold])])
    }

    @Test("a run past the end of the text is clipped to it")
    func clipsToText() {
        let spans = [Span(start: 2, length: 50, marks: [.italic])]
        #expect(InlineSpans.normalized(spans, textLength: 5) == [Span(start: 2, length: 3, marks: [.italic])])
    }

    @Test("overlapping runs merge their marks")
    func overlapUnion() {
        let spans = [
            Span(start: 0, length: 4, marks: [.bold]),
            Span(start: 2, length: 4, marks: [.italic]),
        ]
        #expect(InlineSpans.normalized(spans, textLength: 6) == [
            Span(start: 0, length: 2, marks: [.bold]),
            Span(start: 2, length: 2, marks: [.bold, .italic]),
            Span(start: 4, length: 2, marks: [.italic]),
        ])
    }

    @Test("marks are stored in a fixed order whatever order they arrive in")
    func marksSorted() {
        let span = Span(start: 0, length: 1, marks: [.strikethrough, .bold, .italic])
        #expect(span.marks == [.bold, .italic, .strikethrough])
    }

    // MARK: - Toggling

    @Test("toggling a mark on a plain range sets it")
    func toggleOn() {
        let result = InlineSpans.toggle(.bold, in: 0..<4, spans: [], textLength: 10)
        #expect(result == [Span(start: 0, length: 4, marks: [.bold])])
    }

    @Test("toggling a mark the whole range already has removes it")
    func toggleOff() {
        let spans = [Span(start: 0, length: 4, marks: [.bold])]
        #expect(InlineSpans.toggle(.bold, in: 0..<4, spans: spans, textLength: 10).isEmpty)
    }

    @Test("toggling a partly-marked range sets the whole of it")
    func togglePartial() {
        let spans = [Span(start: 0, length: 2, marks: [.bold])]
        let result = InlineSpans.toggle(.bold, in: 0..<4, spans: spans, textLength: 10)
        #expect(result == [Span(start: 0, length: 4, marks: [.bold])])
    }

    @Test("toggling one mark leaves the others alone")
    func toggleKeepsOthers() {
        let spans = [Span(start: 0, length: 4, marks: [.bold, .italic])]
        let result = InlineSpans.toggle(.bold, in: 0..<4, spans: spans, textLength: 10)
        #expect(result == [Span(start: 0, length: 4, marks: [.italic])])
    }

    // MARK: - Reading

    @Test("a toolbar shows a mark active only when the whole selection has it")
    func marksInRange() {
        let spans = [Span(start: 0, length: 2, marks: [.bold])]
        #expect(InlineSpans.marks(in: 0..<2, spans: spans, textLength: 6) == [.bold])
        #expect(InlineSpans.marks(in: 0..<4, spans: spans, textLength: 6) == [])
    }

    @Test("an empty selection inherits from the character before it")
    func caretInherits() {
        let spans = [Span(start: 0, length: 3, marks: [.bold])]
        // Caret just after the bold run: typing continues bold.
        #expect(InlineSpans.marks(in: 3..<3, spans: spans, textLength: 6) == [.bold])
        // Caret at the very start: nothing to inherit, so typing is plain.
        #expect(InlineSpans.marks(in: 0..<0, spans: spans, textLength: 6) == [])
    }

    // MARK: - Following an edit

    @Test("text inserted after a run continues its formatting")
    func insertContinues() {
        let spans = [Span(start: 0, length: 4, marks: [.bold])]
        let result = InlineSpans.adjusted(spans, textLength: 4, replacing: 4..<4, withLength: 3)
        #expect(result == [Span(start: 0, length: 7, marks: [.bold])])
    }

    @Test("text inserted before a run does not take its formatting")
    func insertBeforeIsPlain() {
        let spans = [Span(start: 0, length: 4, marks: [.bold])]
        let result = InlineSpans.adjusted(spans, textLength: 4, replacing: 0..<0, withLength: 2)
        #expect(result == [Span(start: 2, length: 4, marks: [.bold])])
    }

    @Test("deleting inside a run shortens it")
    func deleteShortens() {
        let spans = [Span(start: 2, length: 6, marks: [.italic])]
        let result = InlineSpans.adjusted(spans, textLength: 10, replacing: 3..<5, withLength: 0)
        #expect(result == [Span(start: 2, length: 4, marks: [.italic])])
    }

    @Test("deleting a whole run removes it")
    func deleteRemoves() {
        let spans = [Span(start: 0, length: 4, marks: [.bold])]
        #expect(InlineSpans.adjusted(spans, textLength: 8, replacing: 0..<4, withLength: 0).isEmpty)
    }

    // MARK: - Moving text between blocks

    @Test("splitting carries each half's formatting with it")
    func sliceForSplit() {
        // "boldplain" with the first four units bold, split after four.
        let spans = [Span(start: 0, length: 4, marks: [.bold])]
        let head = InlineSpans.slice(spans, textLength: 9, range: 0..<4)
        let tail = InlineSpans.slice(spans, textLength: 9, range: 4..<9)

        #expect(head == [Span(start: 0, length: 4, marks: [.bold])])
        #expect(tail.isEmpty)
    }

    @Test("a slice from the middle is rebased to zero")
    func sliceRebases() {
        let spans = [Span(start: 4, length: 3, marks: [.underline])]
        #expect(InlineSpans.slice(spans, textLength: 10, range: 3..<8)
                == [Span(start: 1, length: 3, marks: [.underline])])
    }

    @Test("merging two blocks shifts the second block's formatting along")
    func concatenation() {
        let first = [Span(start: 0, length: 2, marks: [.bold])]
        let second = [Span(start: 1, length: 2, marks: [.italic])]
        let result = InlineSpans.concatenated(first, firstLength: 5, second, secondLength: 4)
        #expect(result == [
            Span(start: 0, length: 2, marks: [.bold]),
            Span(start: 6, length: 2, marks: [.italic]),
        ])
    }

    // MARK: - Links

    @Test("a link is reported only when it covers the whole range")
    func linkCoverage() {
        let spans = [Span(start: 0, length: 4, marks: [], link: "https://example.com")]
        #expect(InlineSpans.link(in: 0..<4, spans: spans, textLength: 10) == "https://example.com")
        #expect(InlineSpans.link(in: 0..<6, spans: spans, textLength: 10) == nil)
    }

    @Test("clearing a link leaves the marks in place")
    func clearLink() {
        let spans = [Span(start: 0, length: 4, marks: [.bold], link: "https://example.com")]
        let result = InlineSpans.setLink(nil, in: 0..<4, spans: spans, textLength: 4)
        #expect(result == [Span(start: 0, length: 4, marks: [.bold])])
    }

    // MARK: - The wire format

    @Test("a block written before inline formatting existed still reads")
    func backwardCompatible() {
        let legacy = #"{"text":"hello","checked":null,"language":null,"attachmentId":null}"#
        let content = BlockContent.decode(legacy)
        #expect(content.text == "hello")
        #expect(content.spans == nil)
        #expect(content.inlineSpans.isEmpty)
    }

    @Test("formatting survives a round trip through the wire format")
    func roundTrip() {
        var content = BlockContent(text: "hello world")
        content.inlineSpans = [Span(start: 0, length: 5, marks: [.bold, .italic], link: "https://example.com")]

        let decoded = BlockContent.decode(content.encoded())
        #expect(decoded.text == "hello world")
        #expect(decoded.inlineSpans == content.inlineSpans)
    }

    /// The bytes Android actually writes, pasted verbatim.
    ///
    /// The two encoders do not produce identical bytes and never have — Kotlin
    /// writes its nulls out and orders keys differently, Swift escapes the
    /// slashes in a URL. That is fine and predates this change. What must hold
    /// is that each side can read the other's file, so both fixtures are pinned
    /// here and in `InlineSpansTest.kt`.
    @Test("a block written by Android reads correctly")
    func readsAndroidBytes() {
        let fromKotlin = #"{"text":"hello world","checked":null,"language":null,"attachmentId":null,"spans":[{"start":0,"length":5,"marks":["bold","italic"],"link":"https://example.com"}]}"#
        let content = BlockContent.decode(fromKotlin)
        #expect(content.text == "hello world")
        #expect(content.inlineSpans == [
            Span(start: 0, length: 5, marks: [.bold, .italic], link: "https://example.com")
        ])
    }

    /// Kotlin defaults `marks` to empty, so a writer that leaves it out is
    /// legal. Swift's synthesized decoder made it required, and the throw came
    /// back from `BlockContent.decode` as empty content — the words gone.
    @Test("a span written without marks reads as an unmarked run")
    func spanWithoutMarks() {
        let fromKotlin = #"{"text":"hello world","spans":[{"start":0,"length":5,"link":"https://example.com"}]}"#
        let content = BlockContent.decode(fromKotlin)
        #expect(content.text == "hello world")
        #expect(content.inlineSpans == [Span(start: 0, length: 5, link: "https://example.com")])
    }

    /// A block is written whole, so an unreadable payload must not come back as
    /// no text: the block would render blank and the next keystroke would write
    /// that blankness back under a newer clock. Mirrored in `InlineSpansTest.kt`.
    @Test("content that cannot be decoded keeps its text")
    func salvagesTextFromUndecodableContent() {
        let broken = #"{"text":"hello world","spans":[{"start":0,"length":5,"marks":["neon"]}]}"#
        let content = BlockContent.decode(broken)
        #expect(content.text == "hello world")
        #expect(content.inlineSpans.isEmpty)
    }

    @Test("offsets are UTF-16 units, so an emoji counts as two")
    func utf16Offsets() {
        // "👋ab" — the wave is one character but two UTF-16 units, so bolding
        // just "a" is offset 2, not offset 1. Counting characters here would put
        // the bold on the wrong letter on whichever platform disagreed.
        let text = "👋ab"
        #expect(text.utf16.count == 4)
        #expect(text.count == 3)

        var content = BlockContent(text: text)
        content.inlineSpans = InlineSpans.toggle(.bold, in: 2..<3, spans: [], textLength: text.utf16.count)
        #expect(content.inlineSpans == [Span(start: 2, length: 1, marks: [.bold])])
    }
}
