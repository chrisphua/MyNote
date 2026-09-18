import Foundation

/// The note a fresh install opens with.
///
/// A blank app teaches nothing, and a block editor has conventions — Return
/// splits, backspace folds upward — that are invisible until someone tries
/// them. This says so in the one place a new user is definitely looking, using
/// the blocks it is describing.
///
/// Defined in core so both platforms seed exactly the same thing. It is an
/// ordinary note: editable, and deletable, and it never comes back.
public enum WelcomeNote {
    public static let title = "Welcome to MyNote"

    public struct Line: Sendable {
        public let type: BlockType
        public let text: String

        public init(_ type: BlockType, _ text: String) {
            self.type = type
            self.text = text
        }
    }

    public static let lines: [Line] = [
        .init(.heading1, "Everything here is a block"),
        .init(.paragraph, "Press Return to start a new one. Backspace at the very start of a block folds it into the one above, so nothing is ever stranded."),
        .init(.paragraph, "The bar above the keyboard changes what a block is. Long-press a block for the same menu, plus Delete."),

        .init(.heading2, "What a block can be"),
        .init(.bullet, "A bulleted list — Return keeps the bullet going"),
        .init(.numbered, "A numbered list"),
        .init(.todo, "A to-do you can tick off"),
        .init(.quote, "A quote, for words that are not yours"),
        .init(.code, "let code = \"for the ones that are\""),
        .init(.divider, ""),

        .init(.heading2, "Make it look how you like"),
        .init(.paragraph, "Settings → Theme. Colours for light and dark, text size, line height, spacing, corners, page width. Build your own and every screen follows it."),

        .init(.heading2, "Your notes stay yours"),
        .init(.paragraph, "MyNote has no servers. Back up to your own iCloud Drive or Google Drive and the files land in a folder you can open, read and delete yourself. We never see them."),
        .init(.paragraph, "Google Drive works on iPhone, iPad and Android. iCloud Drive is Apple-only — Apple provides no way for an Android app to read it."),

        .init(.paragraph, "Delete this note whenever you like. It will not come back."),
    ]
}
