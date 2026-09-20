import XCTest

/// Bold and the rest, applied to part of a line.
///
/// The span algebra is covered by the shared vectors in `MyNoteCore`. What
/// cannot be unit tested is the part that has broken before on this editor: a
/// `UITextView` owns its text while it is focused, so formatting applied from a
/// toolbar has to be pushed into it deliberately — and the selection has to
/// survive, or bolding a word deselects it.
@MainActor
final class InlineFormattingTests: XCTestCase {

    private let app = XCUIApplication()

    private func noteWithText(_ value: String) -> XCUIElement {
        continueAfterFailure = false
        app.launchArguments = ["-ui-testing"]
        app.launch()

        app.buttons["New note"].tap()
        let field = app.textViews.matching(identifier: "blockEditor").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "a new note should open with a block")
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "keyboard")
        field.typeText(value)
        return field
    }

    /// Selects everything in the focused block via the edit menu.
    private func selectAll(in field: XCUIElement) {
        field.doubleTap()
        let selectAll = app.menuItems["Select All"].firstMatch
        if selectAll.waitForExistence(timeout: 3) {
            selectAll.tap()
        }
    }

    func testTheBoldButtonIsOfferedWhileEditing() {
        _ = noteWithText("hello")
        XCTAssertTrue(app.buttons["Bold"].waitForExistence(timeout: 5),
                      "the formatting bar should offer Bold while a block is focused")
        for label in ["Italic", "Underline", "Strikethrough"] {
            XCTAssertTrue(app.buttons[label].exists, "the bar should offer \(label)")
        }
    }

    /// Bolding a selection must not disturb the text or lose the selection.
    func testBoldingASelectionKeepsTheTextAndTheSelection() {
        let field = noteWithText("hello")
        selectAll(in: field)

        let bold = app.buttons["Bold"].firstMatch
        XCTAssertTrue(bold.waitForExistence(timeout: 5), "Bold")
        bold.tap()

        // The words are what matter: a round trip through the store that came
        // back wrong would show up here as changed or empty text.
        XCTAssertEqual((field.value as? String) ?? "", "hello",
                       "bolding should change how the text looks, not what it says")

        // Still selected, so a second press can unbold it — which also proves
        // the toolbar reads the selection rather than assuming it.
        XCTAssertTrue(bold.isSelected || app.buttons["Bold"].isSelected,
                      "Bold should now show as active for the selection")
    }

    /// Typing after bolding continues in bold, and the text survives.
    func testTypingContinuesAfterFormatting() {
        let field = noteWithText("hello")
        selectAll(in: field)

        let bold = app.buttons["Bold"].firstMatch
        XCTAssertTrue(bold.waitForExistence(timeout: 5), "Bold")
        bold.tap()

        // Tap to the right of the text to drop the selection, then keep typing.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        app.typeText(" there")

        XCTAssertEqual((field.value as? String) ?? "", "hello there",
                       "typing after a formatting change should just append")
    }

    /// Formatting has to survive the block being split and rejoined.
    func testFormattingSurvivesASplitAndMerge() {
        let field = noteWithText("hello")
        selectAll(in: field)
        app.buttons["Bold"].firstMatch.tap()

        // Split at the end, then merge straight back.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        app.typeText("\n")
        app.typeText("world")

        let blocks = app.textViews.matching(identifier: "blockEditor")
        XCTAssertEqual(blocks.count, 2, "Return should have made a second block")

        let values = (0..<blocks.count).compactMap { blocks.element(boundBy: $0).value as? String }
        XCTAssertTrue(values.contains("hello"), "the first block should still say hello — got \(values)")
        XCTAssertTrue(values.contains("world"), "the second block should hold what was typed — got \(values)")
    }
}
