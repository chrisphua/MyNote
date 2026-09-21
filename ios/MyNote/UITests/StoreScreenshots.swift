import XCTest

/// Captures the App Store screenshots.
///
/// Not a test of anything — it drives the app to each screen worth showing and
/// attaches a full-screen capture. Apple requires one set per device size, and
/// taking them by hand means redoing every one whenever a colour or a string
/// changes. Run it per simulator and pull the PNGs out of the result bundle:
///
///     xcodebuild test -project MyNote.xcodeproj -scheme MyNote \
///       -only-testing:MyNoteUITests/StoreScreenshots \
///       -destination 'id=<simulator udid>' -resultBundlePath shots.xcresult
///     xcrun xcresulttool export attachments \
///       --path shots.xcresult --output-path <dir>
///
/// Deliberately launched *without* `-ui-testing`, unlike the editor tests: that
/// flag skips seeding the welcome note, and the welcome note is the content the
/// screenshots are of.
@MainActor
final class StoreScreenshots: XCTestCase {

    private let app = XCUIApplication()

    /// Attaches a full-screen capture under a name that sorts into store order.
    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testCaptureStoreScreenshots() {
        continueAfterFailure = false

        // Portrait throughout. Rotating the iPad gave a landscape layout inside
        // a portrait-sized image — a sideways screenshot the store would reject.
        XCUIDevice.shared.orientation = .portrait
        // Wipe, but keep the welcome note: these are pictures of a first launch,
        // and a store left over from another test is not that.
        app.launchArguments = ["-fresh-install"]
        app.launch()

        // 1 — the list, with the note every new install is given.
        //
        // On an iPad in portrait the split view starts with the sidebar closed,
        // so the first thing on screen is the empty detail pane. Open it, or the
        // screenshot is of nothing at all.
        var welcome = app.staticTexts["Welcome to MyNote"].firstMatch
        if !welcome.waitForExistence(timeout: 10) {
            app.navigationBars.buttons.firstMatch.tap()
            welcome = app.staticTexts["Welcome to MyNote"].firstMatch
            XCTAssertTrue(welcome.waitForExistence(timeout: 10), "the welcome note should be seeded on a fresh install")
        }
        capture("01-list")

        // 2 — the editor, showing what a block can be.
        let firstBlock = app.textViews.matching(identifier: "blockEditor").firstMatch
        if !firstBlock.exists {
            welcome.tap()
        }
        XCTAssertTrue(firstBlock.waitForExistence(timeout: 10), "the note should open into the block editor")
        capture("02-editor")

        // 3 — the formatting bar, which only appears while a block is focused.
        firstBlock.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        // The bar follows the focused block, not the keyboard — and a simulator
        // with a hardware keyboard attached never shows a software one.
        _ = app.keyboards.firstMatch.waitForExistence(timeout: 5)
        XCTAssertTrue(app.buttons["Bulleted list"].waitForExistence(timeout: 5), "focusing a block should show the formatting bar")
        capture("03-formatting")

        // 4 — where the notes are kept, which is the whole argument for the app.
        if app.buttons["Done"].firstMatch.exists {
            app.buttons["Done"].firstMatch.tap()
        }
        // iOS labels a back button with the *previous* screen's title, so there
        // is never a button called "Back" to look for — take the leading one.
        let settings = app.buttons["Settings"].firstMatch
        if !settings.exists {
            app.navigationBars.buttons.firstMatch.tap()
        }
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "the list should offer Settings")
        settings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5), "Settings should open")
        capture("04-backup")

        // 5 — themes. Below the fold, and a SwiftUI list does not render a row
        //     it has never scrolled to, so this has to actually scroll.
        for _ in 0..<3 where !app.buttons["Sepia"].exists {
            app.swipeUp()
        }
        XCTAssertTrue(app.buttons["Sepia"].waitForExistence(timeout: 5), "Settings should list the built-in themes")
        capture("05-themes")
    }
}
