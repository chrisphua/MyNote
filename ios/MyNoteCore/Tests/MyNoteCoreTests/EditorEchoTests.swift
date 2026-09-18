import Testing
@testable import MyNoteCore

@Suite("Editor echo")
struct EditorEchoTests {

    @Test("loads the first value from the store")
    func adoptsInitialValue() {
        let echo = EditorEcho()
        #expect(echo.shouldAdopt("from the database"))
    }

    @Test("ignores its own write coming back")
    func ignoresOwnEcho() {
        var echo = EditorEcho()
        echo.sending("hello")
        #expect(echo.shouldAdopt("hello") == false)
    }

    @Test("a stale write does not clobber what the user has typed since")
    func staleEchoIsStillIgnoredForTheCurrentValue() {
        // This is the bug: the user types "ab", the store echoes the earlier
        // "a", and the editor adopts it — losing a character and, when the stale
        // value is the block's original empty string, emptying the field and
        // showing the placeholder again.
        var echo = EditorEcho()
        echo.sending("a")
        echo.sending("ab")

        #expect(echo.shouldAdopt("ab") == false, "the current value is our own echo")
        #expect(echo.shouldAdopt("a") == false, "the stale echo must not clobber the field")
        #expect(echo.shouldAdopt(""), "a genuinely different value is a real edit")
    }

    @Test("an empty echo of an empty write is still an echo")
    func emptyEcho() {
        var echo = EditorEcho()
        echo.sending("")
        #expect(echo.shouldAdopt("") == false)
    }

    @Test("history is bounded, so it cannot grow without limit while typing")
    func historyIsBounded() {
        var echo = EditorEcho()
        for i in 0..<200 { echo.sending("value \(i)") }

        #expect(echo.shouldAdopt("value 199") == false, "recent writes are still recognised")
        #expect(echo.shouldAdopt("value 0"), "ancient writes fall out of the history")
    }

    @Test("adopts an edit made on another device")
    func adoptsRemoteEdit() {
        var echo = EditorEcho()
        echo.sending("mine")
        #expect(echo.shouldAdopt("theirs"))
    }
}
