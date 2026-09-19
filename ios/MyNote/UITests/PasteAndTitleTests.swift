import XCTest
import UIKit

/// Pasting, and editing a title that already has text in it.
///
/// Both were reported from a real device: a large paste locked the editor up,
/// and after pasting into a title it became impossible to insert a word
/// anywhere but the end.
@MainActor
final class PasteAndTitleTests: XCTestCase {

    private let app = XCUIApplication()

    /// Roughly an article's worth of prose — what someone actually pastes into
    /// a note, rather than a token string that proves nothing about layout.
    private static let bigChunk: String = {
        let paragraph = """
        The quick brown fox jumps over the lazy dog, and having done so, \
        considers the matter closed. It is a sentence that exists to hold every \
        letter, not to say anything, which makes it a fair test of a text view \
        that has to lay out and measure whatever it is handed.
        """
        return (0..<220).map { "\($0). \(paragraph)" }.joined(separator: "\n\n")
    }()

    private func openNewNote() -> XCUIElement {
        continueAfterFailure = false
        app.launchArguments = ["-ui-testing"]
        app.launch()

        app.buttons["New note"].tap()
        let field = app.textViews.matching(identifier: "blockEditor").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "a new note should open with a block to type in")
        return field
    }

    /// Pastes the pasteboard into an already-focused field.
    ///
    /// `typeKey` needs a hardware keyboard the simulator may not have attached,
    /// and silently does nothing without one — which makes a paste test pass
    /// while pasting nothing at all. The edit menu is the reliable route, so it
    /// is tried first and the keystroke is only the fallback.
    private func pasteIntoFocusedField(_ field: XCUIElement) {
        field.doubleTap()
        let pasteItem = app.menuItems["Paste"].firstMatch
        if pasteItem.waitForExistence(timeout: 3) {
            pasteItem.tap()
            return
        }
        app.typeKey("v", modifierFlags: .command)
    }

    private func paste(into field: XCUIElement) {
        UIPasteboard.general.string = Self.bigChunk

        field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "tapping a block should raise the keyboard")
        pasteIntoFocusedField(field)

        // The paste lands across many blocks, so wait on the note as a whole.
        // Without this the timings below would happily measure nothing.
        let landed = NSPredicate(format: "count > 1")
        expectation(for: landed, evaluatedWith: app.textViews.matching(identifier: "blockEditor"))
        waitForExpectations(timeout: 30)
    }

    private var blockValues: [String] {
        let blocks = app.textViews.matching(identifier: "blockEditor")
        return (0..<blocks.count).compactMap { blocks.element(boundBy: $0).value as? String }
    }

    /// The reported freeze: paste a large chunk and the editor stops responding.
    func testPastingALargeChunkLeavesTheEditorResponsive() {
        let field = openNewNote()
        paste(into: field)

        // A paste of paragraphs should become paragraphs, not one enormous
        // block — which is both the right shape and what keeps it quick.
        let blocks = app.textViews.matching(identifier: "blockEditor").count
        XCTAssertGreaterThan(blocks, 1, "a multi-paragraph paste should make blocks")

        let bullet = app.buttons["Bulleted list"].firstMatch
        XCTAssertTrue(bullet.waitForExistence(timeout: 20), "the formatting bar should still be there after a paste")

        let tapStarted = Date()
        bullet.tap()
        let tapElapsed = Date().timeIntervalSince(tapStarted)

        // Typing is what a person actually notices seizing up.
        let typeStarted = Date()
        app.typeText("X")
        let typeElapsed = Date().timeIntervalSince(typeStarted)

        // Generous, because XCUITest's own per-keystroke overhead is most of a
        // second on its own — see the control test below. This is a guard
        // against the freeze coming back, not a benchmark.
        print("PASTE-TIMING tap=\(tapElapsed)s type=\(typeElapsed)s blocks=\(blocks)")
        XCTAssertLessThan(tapElapsed, 3.0, "a tap after a large paste took \(tapElapsed)s")
        XCTAssertLessThan(typeElapsed, 3.0, "typing after a large paste took \(typeElapsed)s")
    }

    /// Return near the end of a long note must still move the caret.
    ///
    /// The stack is lazy, so the new block may not be rendered yet — and a block
    /// that does not exist cannot take focus. Android had exactly this: five
    /// Returns left five empty blocks and typed every line into the block above.
    func testReturnNearTheEndOfALongNoteTypesIntoTheNewBlock() {
        let field = openNewNote()
        paste(into: field)

        let blocks = app.textViews.matching(identifier: "blockEditor")
        let last = blocks.element(boundBy: blocks.count - 1)
        last.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "keyboard")

        let original = (last.value as? String) ?? ""
        XCTAssertFalse(original.isEmpty, "should have tapped into a block with text")

        // Typed at the app, not the element: after Return the focus is in the
        // new block, and addressing the old one would be asserting the bug.
        app.typeText("\n")
        app.typeText("ZZTOP")

        let values = blockValues
        XCTAssertFalse(
            values.contains(original + "ZZTOP"),
            "the text went back into the block that was split, so the caret never moved"
        )
        XCTAssertTrue(
            values.contains("ZZTOP"),
            "the new block should hold what was typed after Return — got \(values.suffix(3))"
        )
    }

    /// The reported title bug: *after pasting*, text can only be added at the end.
    func testAWordCanBeInsertedIntoATitleThatWasPastedInto() {
        _ = openNewNote()

        // The only text field on the screen; a SwiftUI TextField carries no
        // identifier, and its placeholder is not queryable by predicate.
        let title = app.textFields.firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5), "the note should have a title field")

        UIPasteboard.general.string = "Quarterly Review"
        title.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "tapping the title should raise the keyboard")
        pasteIntoFocusedField(title)

        let pasted = (title.value as? String) ?? ""
        XCTAssertEqual(pasted, "Quarterly Review", "the paste should land in the title")

        // Put the caret at the very start and type. Bound straight to the store,
        // a keystroke came back from SwiftData and shunted the caret to the end.
        title.coordinate(withNormalizedOffset: CGVector(dx: 0.001, dy: 0.5)).tap()
        title.typeText("A")

        XCTAssertEqual(
            (title.value as? String) ?? "", "AQuarterly Review",
            "typing at the start of a pasted title should insert there, not jump to the end"
        )
    }

    /// Control: the same measurement in an empty note.
    ///
    /// Without it the paste timings mean nothing — XCUITest's own overhead per
    /// keystroke is easily large enough to swamp the thing being measured.
    func testTypingSpeedInAnEmptyNoteAsAControl() {
        let field = openNewNote()
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "keyboard")

        let started = Date()
        app.typeText("X")
        print("CONTROL-TIMING type=\(Date().timeIntervalSince(started))s")
    }
}
