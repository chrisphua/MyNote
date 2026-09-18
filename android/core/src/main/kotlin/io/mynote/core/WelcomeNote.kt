package io.mynote.core

/**
 * The note a fresh install opens with.
 *
 * A blank app teaches nothing, and a block editor has conventions — Return
 * splits, backspace folds upward — that are invisible until someone tries them.
 * This says so in the one place a new user is definitely looking, using the
 * blocks it is describing.
 *
 * Defined in core so both platforms seed exactly the same thing. It is an
 * ordinary note: editable, and deletable, and it never comes back.
 */
object WelcomeNote {
    const val TITLE = "Welcome to MyNote"

    data class Line(val type: BlockType, val text: String)

    val lines: List<Line> = listOf(
        Line(BlockType.HEADING1, "Everything here is a block"),
        Line(BlockType.PARAGRAPH, "Press Return to start a new one. Backspace at the very start of a block folds it into the one above, so nothing is ever stranded."),
        Line(BlockType.PARAGRAPH, "The bar above the keyboard changes what a block is. Long-press a block for the same menu, plus Delete."),

        Line(BlockType.HEADING2, "What a block can be"),
        Line(BlockType.BULLET, "A bulleted list — Return keeps the bullet going"),
        Line(BlockType.NUMBERED, "A numbered list"),
        Line(BlockType.TODO_ITEM, "A to-do you can tick off"),
        Line(BlockType.QUOTE, "A quote, for words that are not yours"),
        Line(BlockType.CODE, "val code = \"for the ones that are\""),
        Line(BlockType.DIVIDER, ""),

        Line(BlockType.HEADING2, "Make it look how you like"),
        Line(BlockType.PARAGRAPH, "Settings → Theme. Colours for light and dark, text size, line height, spacing, corners, page width. Build your own and every screen follows it."),

        Line(BlockType.HEADING2, "Your notes stay yours"),
        Line(BlockType.PARAGRAPH, "MyNote has no servers. Back up to your own Google Drive and the files land in a folder you can open, read and delete yourself. We never see them."),
        Line(BlockType.PARAGRAPH, "Google Drive works on Android, iPhone and iPad, so the same notes reach all of them."),

        Line(BlockType.PARAGRAPH, "Delete this note whenever you like. It will not come back."),
    )
}
