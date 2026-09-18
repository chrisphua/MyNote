package io.mynote.core

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class EditorEchoTest {

    @Test
    fun `loads the first value from the store`() {
        assertTrue(EditorEcho().shouldAdopt("from the database"))
    }

    @Test
    fun `ignores its own write coming back`() {
        val echo = EditorEcho()
        echo.sending("hello")
        assertFalse(echo.shouldAdopt("hello"))
    }

    @Test
    fun `a stale write does not clobber what the user has typed since`() {
        // This is the bug: the user types "ab", the store echoes the earlier
        // "a", and the editor adopts it — losing a character and, when the stale
        // value is the block's original empty string, emptying the field and
        // showing the placeholder again.
        val echo = EditorEcho()
        echo.sending("a")
        echo.sending("ab")

        assertFalse("the current value is our own echo", echo.shouldAdopt("ab"))
        assertFalse("the stale echo must not clobber the field", echo.shouldAdopt("a"))
        assertTrue("a genuinely different value is a real edit", echo.shouldAdopt(""))
    }

    @Test
    fun `an empty echo of an empty write is still an echo`() {
        val echo = EditorEcho()
        echo.sending("")
        assertFalse(echo.shouldAdopt(""))
    }

    @Test
    fun `history is bounded, so it cannot grow without limit while typing`() {
        val echo = EditorEcho()
        repeat(200) { echo.sending("value $it") }

        assertFalse("recent writes are still recognised", echo.shouldAdopt("value 199"))
        assertTrue("ancient writes fall out of the history", echo.shouldAdopt("value 0"))
    }

    @Test
    fun `adopts an edit made on another device`() {
        val echo = EditorEcho()
        echo.sending("mine")
        assertTrue(echo.shouldAdopt("theirs"))
    }
}
