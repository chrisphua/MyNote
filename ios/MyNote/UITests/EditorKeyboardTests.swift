import XCTest

/// The editor's keyboard behaviour.
///
/// Return and backspace only mean anything against a real text view with a real
/// caret, so these cannot be unit tests. They exist because both interactions
/// shipped broken: `TextField(axis: .vertical)` swallowed Return as a newline,
/// and nothing handled backspace at all, which left an empty block impossible to
/// remove from the keyboard.
final class EditorKeyboardTests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-ui-testing"]
        app.launch()
    }

    /// Opens a fresh note and returns its first block field, focused.
    private func newNote() -> XCUIElement {
        app.buttons["New note"].tap()

        let field = app.textViews.matching(identifier: "blockEditor").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "a new note should open with a block to type in")
        focus(field)
        return field
    }

    /// Taps by coordinate rather than `tap()`.
    ///
    /// The push transition can still be settling when the field first exists, so
    /// `tap()` intermittently reports it as not hittable. A coordinate tap lands
    /// on the same point without that check.
    private func focus(_ field: XCUIElement) {
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(
            app.keyboards.firstMatch.waitForExistence(timeout: 5),
            "tapping a block should raise the keyboard"
        )
    }

    private var blockCount: Int {
        app.textViews.matching(identifier: "blockEditor").count
    }

    /// Block text, ordered the way the reader sees it.
    ///
    /// `element(boundBy:)` walks the accessibility tree, which is not promised
    /// to match visual order — so the position on screen is what to sort by.
    private var blockValues: [String] {
        let fields = app.textViews.matching(identifier: "blockEditor")
        return (0..<fields.count)
            .map { fields.element(boundBy: $0) }
            .sorted { $0.frame.minY < $1.frame.minY }
            .map { $0.value as? String ?? "nil" }
    }

    func testReturnCreatesANewBlock() {
        let field = newNote()
        XCTAssertEqual(blockCount, 1)

        field.typeText("first line")
        field.typeText("\n")

        XCTAssertEqual(blockCount, 2, "Return should split the block, not insert a newline")
    }

    func testReturnAtTheEndLeavesTheTextWhereItWas() {
        // Splitting mid-text needs the caret moved, and the software keyboard
        // has no arrow keys — that case is covered by the repository tests in
        // `EditorOperationsTests` instead. This covers the common path.
        let field = newNote()
        field.typeText("first")
        field.typeText("\n")
        app.typeText("second")

        XCTAssertEqual(blockValues, ["first", "second"])
    }

    func testBackspaceRemovesAnEmptyBlock() {
        // The reported bug: an empty block showing its placeholder could not be
        // deleted with backspace, only through the long-press menu.
        let field = newNote()
        field.typeText("kept")
        field.typeText("\n")
        XCTAssertEqual(blockCount, 2)

        // Return already leaves the new, empty block focused, so type straight
        // into whatever holds focus rather than tapping and risking a miss.
        app.typeText(XCUIKeyboardKey.delete.rawValue)

        XCTAssertEqual(blockValues, ["kept"], "backspace in an empty block should remove it")
    }

    func testBackspaceMergesTextIntoTheBlockAbove() {
        let field = newNote()
        field.typeText("one")
        field.typeText("\n")
        app.typeText("two")

        // Put the caret before "two". The software keyboard has no arrow keys,
        // and tapping a field that already holds focus does not move the caret —
        // so focus is moved away first, and the tap that brings it back lands
        // the caret where it was tapped.
        let fields = app.textViews.matching(identifier: "blockEditor")
        let first = fields.element(boundBy: 0)
        let second = fields.element(boundBy: 1)

        first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        second.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5)).tap()
        app.typeText(XCUIKeyboardKey.delete.rawValue)

        XCTAssertEqual(blockValues, ["onetwo"], "the two blocks should be joined, losing nothing")
    }

    func testBackspaceInTheFirstBlockKeepsTheNote() {
        let field = newNote()
        // Typed first, so this cannot pass merely because nothing happened.
        field.typeText("only block")
        field.typeText(XCUIKeyboardKey.delete.rawValue)

        XCTAssertEqual(blockCount, 1, "a note must always have somewhere to type")
        XCTAssertEqual(field.value as? String, "only bloc", "backspace should still delete a character")
    }

    func testTypingIsNotClobberedByItsOwnSave() {
        // The placeholder used to reappear mid-sentence: an asynchronous write
        // echoed back a stale value and overwrote the field.
        let field = newNote()
        let sentence = "the quick brown fox jumps over the lazy dog"
        field.typeText(sentence)

        XCTAssertEqual(field.value as? String, sentence, "no characters should be lost while typing")
    }
}
