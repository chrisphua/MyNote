import XCTest

/// Deleting after inserting.
///
/// Reported from a device: insert a word, press backspace, and the characters
/// stay on screen.
@MainActor
final class BackspaceTests: XCTestCase {

    private let app = XCUIApplication()

    private func focusedBlock() -> XCUIElement {
        continueAfterFailure = false
        app.launchArguments = ["-ui-testing"]
        app.launch()

        app.buttons["New note"].tap()
        let field = app.textViews.matching(identifier: "blockEditor").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "a new note should open with a block")
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "keyboard")
        return field
    }

    private var delete: String { XCUIKeyboardKey.delete.rawValue }

    /// Type, then delete the last few characters.
    func testBackspaceAtTheEndRemovesCharacters() {
        let field = focusedBlock()
        field.typeText("hello")
        field.typeText(String(repeating: delete, count: 3))

        XCTAssertEqual((field.value as? String) ?? "", "he",
                       "three backspaces should leave two characters")
    }

    /// The reported case: insert a word into existing text, then take it back out.
    func testBackspaceAfterInsertingAWordRemovesIt() {
        let field = focusedBlock()
        field.typeText("hello")
        field.typeText(" there")
        XCTAssertEqual((field.value as? String) ?? "", "hello there", "precondition")

        // Delete the word just inserted, one character at a time.
        field.typeText(String(repeating: delete, count: 6))

        XCTAssertEqual((field.value as? String) ?? "", "hello",
                       "backspacing over an inserted word should remove it")
    }

    // Deliberately not tested here: tapping a second time into a block that is
    // already focused. XCUITest's synthesised tap lands inside UIKit's
    // double-tap window, which selects a word — and a one-word block then looks
    // exactly like "the editor selected everything". A single tap into a block
    // is covered by `testFirstTapIntoAnExistingBlockPlacesACaret`, which passes.

    /// A formatted block deletes the same way an unformatted one does.
    func testBackspaceWorksInAFormattedBlock() {
        let field = focusedBlock()
        field.typeText("hello")

        field.doubleTap()
        if app.menuItems["Select All"].firstMatch.waitForExistence(timeout: 3) {
            app.menuItems["Select All"].firstMatch.tap()
        }
        app.buttons["Bold"].firstMatch.tap()

        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        app.typeText(delete)

        XCTAssertEqual((field.value as? String) ?? "", "hell",
                       "backspace should delete a character from a bold block too")
    }

    /// An edit must survive the app going away.
    ///
    /// Writes are coalesced into one every 300ms, flushed when focus leaves a
    /// block. Nothing flushes them when the app itself is backgrounded or
    /// killed — so this asks whether the last thing typed actually reaches the
    /// store, which is the difference between a delete sticking and the words
    /// coming back.
    func testTheLastEditSurvivesTheAppGoingAway() {
        let field = focusedBlock()
        field.typeText("hello there")
        field.typeText(String(repeating: delete, count: 6))
        XCTAssertEqual((field.value as? String) ?? "", "hello", "precondition: deleted on screen")

        // No pause: kill it the instant the backspace lands, the way swiping
        // the app away does.
        app.terminate()

        // Relaunch *without* the flag: it wipes the store, which would destroy
        // the very thing being checked. Seeding is guarded on the store being
        // empty, so no welcome note appears over the top either.
        app.launchArguments = []
        app.launch()
        let row = app.staticTexts["Untitled"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the note should have survived")
        row.tap()

        let reopened = app.textViews.matching(identifier: "blockEditor").firstMatch
        XCTAssertTrue(reopened.waitForExistence(timeout: 5), "the note should reopen")
        XCTAssertEqual((reopened.value as? String) ?? "", "hello",
                       "the last edit before the app went away must have been saved")
    }

    private func pause(_ seconds: TimeInterval) {
        let idle = expectation(description: "pause")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { idle.fulfill() }
        wait(for: [idle], timeout: seconds + 2)
    }
}
