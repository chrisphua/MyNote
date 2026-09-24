package io.mynote.core

/**
 * The note a fresh install opens with.
 *
 * A blank app teaches nothing, and a block editor has conventions — Return
 * splits, backspace folds upward — that are invisible until someone tries them.
 * This says so in the one place a new user is definitely looking, using the
 * blocks it is describing.
 *
 * Defined in core so both platforms seed the same thing. It is an ordinary
 * note: editable, and deletable, and it never comes back.
 *
 * The closing section is the one part that varies, because the platforms
 * genuinely do: iOS can always back up, to iCloud Drive, so its copy is
 * unconditional. Android's only destination is Google Drive, and a build with
 * no OAuth client id hides backup altogether — so promising it there would
 * send the reader looking for a Settings section that is not on screen.
 */
object WelcomeNote {
    const val TITLE = "Welcome to MyNote"

    data class Line(val type: BlockType, val text: String)

    /**
     * @param backupAvailable whether this build can actually back up. When it
     * cannot, the note says what is true of it — the notes stay on the device —
     * instead of describing something the reader cannot find.
     */
    fun lines(backupAvailable: Boolean): List<Line> =
        TEACHING + storage(backupAvailable) + FAREWELL

    private val TEACHING = listOf(
        Line(BlockType.HEADING1, "Everything here is a block"),
        Line(BlockType.PARAGRAPH, "Press Return to start a new one. Backspace at the very start of a block folds it into the one above, so nothing is ever stranded."),
        Line(BlockType.PARAGRAPH, "The bar above the keyboard changes what a block is, and makes a word bold, italic, underlined or struck through."),

        Line(BlockType.HEADING2, "What a block can be"),
        Line(BlockType.BULLET, "A bulleted list — Return keeps the bullet going"),
        Line(BlockType.NUMBERED, "A numbered list"),
        Line(BlockType.TODO_ITEM, "A to-do you can tick off"),
        Line(BlockType.QUOTE, "A quote, for words that are not yours"),
        Line(BlockType.CODE, "val code = \"for the ones that are\""),
        Line(BlockType.DIVIDER, ""),

        Line(BlockType.HEADING2, "Make it look how you like"),
        Line(BlockType.PARAGRAPH, "Settings → Theme. Colours for light and dark, text size, line height, spacing, corners, page width. Build your own and every screen follows it."),
    )

    private fun storage(backupAvailable: Boolean) = listOf(
        Line(BlockType.HEADING2, "Your notes stay yours"),
    ) + if (backupAvailable) {
        listOf(
            Line(BlockType.PARAGRAPH, "MyNote has no servers. Back up to your own Google Drive and the files land in a folder you can open, read and delete yourself. We never see them."),
            Line(BlockType.PARAGRAPH, "Google Drive works on Android, iPhone and iPad, so the same notes reach all of them."),
        )
    } else {
        listOf(
            Line(BlockType.PARAGRAPH, "MyNote has no servers, so there is nowhere for your notes to go. They are written to this device and stay on it — no account, nothing to sign in to, and nothing sent anywhere."),
        )
    }

    private val FAREWELL = listOf(
        Line(BlockType.PARAGRAPH, "Delete this note whenever you like. It will not come back."),
    )
}
