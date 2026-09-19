import SwiftUI
import UIKit

/// Where the caret should land after a structural edit.
struct CaretRequest: Equatable {
    let blockId: String
    /// Character offset, or `nil` for the end of the text.
    let offset: Int?

    static func end(of blockId: String) -> CaretRequest {
        CaretRequest(blockId: blockId, offset: nil)
    }
}

/// The editable text of one block.
///
/// A `UITextView` rather than SwiftUI's `TextField`, because a block editor needs
/// two things `TextField` cannot express:
///
/// - **Return splits the block.** A `TextField` with `axis: .vertical` inserts a
///   newline and never calls `onSubmit`, so Return could not create a block.
/// - **Backspace at the start merges into the block above.** There is no SwiftUI
///   hook for "delete pressed with an empty selection at offset 0", which is the
///   only way to get rid of an empty block from the keyboard.
///
/// Both are intercepted below, and both need the caret offset — which
/// `TextField` also does not expose.
struct BlockTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var focusedBlockId: String?
    @Binding var caret: CaretRequest?

    let blockId: String
    let placeholder: String
    let font: UIFont
    let textColor: UIColor
    let placeholderColor: UIColor
    let tintColor: UIColor
    let lineSpacing: CGFloat

    /// Return was pressed. Carries the text before and after the caret.
    let onSplit: (String, String) -> Void
    /// Backspace was pressed with the caret at offset 0.
    let onMergeBackwards: () -> Void
    /// Text containing line breaks arrived at once — a paste. Carries the text
    /// either side of it and the paragraphs themselves.
    let onPasteParagraphs: (String, [String], String) -> Void

    func makeUIView(context: Context) -> InterceptingTextView {
        let view = InterceptingTextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.isScrollEnabled = false          // so it grows with its content
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = true
        // Stable handle for the UI tests; block ids are UUIDs and change per run.
        view.accessibilityIdentifier = "blockEditor"

        view.onDeleteBackwardAtStart = { [weak view] in
            guard let view, view.selectedRange == NSRange(location: 0, length: 0) else { return false }
            context.coordinator.parent.onMergeBackwards()
            return true
        }

        view.placeholderLabel.numberOfLines = 0
        view.addSubview(view.placeholderLabel)
        return view
    }

    func updateUIView(_ view: InterceptingTextView, context: Context) {
        context.coordinator.parent = self

        // While the field is being typed in, it is the source of truth.
        //
        // SwiftUI's copy always lags by at least one render: the view reports a
        // keystroke, the binding updates, and `updateUIView` runs with a value
        // the user has already typed past. Writing that back drops every
        // character typed in between — which is exactly what it did, turning
        // "the quick brown fox" into "the qin x js".
        //
        // Anything genuinely external is applied when focus leaves, and is
        // filtered by `EditorEcho` before it ever reaches this binding.
        let ownsText = view.isFirstResponder
        if !ownsText, view.text != text {
            view.attributedText = styled(text)
            view.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        } else if view.font != font || view.textColor != textColor {
            let selected = view.selectedRange
            view.attributedText = styled(view.text)
            view.selectedRange = selected
        }

        view.tintColor = tintColor
        view.placeholderLabel.text = placeholder
        view.placeholderLabel.font = font
        view.placeholderLabel.textColor = placeholderColor
        view.placeholderLabel.isHidden = !text.isEmpty
        view.setNeedsLayout()

        // Focus and caret are driven from the editor, so a split or merge can
        // say exactly where typing should continue.
        if focusedBlockId == blockId {
            if !view.isFirstResponder { view.becomeFirstResponder() }
            if let caret, caret.blockId == blockId {
                let length = (view.text as NSString).length
                let location = min(caret.offset ?? length, length)
                view.selectedRange = NSRange(location: location, length: 0)
                DispatchQueue.main.async { self.caret = nil }
            }
        } else if view.isFirstResponder {
            view.resignFirstResponder()
        }
    }

    /// `sizeThatFits` is what lets the row grow as the text wraps.
    ///
    /// Cached, because the text view does not scroll — so measuring it lays out
    /// every line of the block, and SwiftUI asks more than once per pass. On a
    /// block holding a pasted article that measurement is the slow part of a
    /// keystroke.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: InterceptingTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? uiView.bounds.width
        guard width > 0 else { return nil }

        let current = uiView.text ?? ""
        if let cached = context.coordinator.measured,
           cached.width == width, cached.font == font, cached.text == current {
            return CGSize(width: width, height: cached.height)
        }

        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let height = max(fitted.height, font.lineHeight)
        context.coordinator.measured = (text: current, width: width, font: font, height: height)
        return CGSize(width: width, height: height)
    }

    private func styled(_ value: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        return NSAttributedString(string: value, attributes: [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraph,
        ])
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: BlockTextView
        /// Last measured height, keyed by what it was measured from.
        var measured: (text: String, width: CGFloat, font: UIFont, height: CGFloat)?

        init(parent: BlockTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            (textView as? InterceptingTextView)?.placeholderLabel.isHidden = !textView.text.isEmpty
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            if parent.focusedBlockId != parent.blockId {
                parent.focusedBlockId = parent.blockId
            }
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText replacement: String
        ) -> Bool {
            // Backspace with the caret at the very start and something to the
            // right of it: fold this block into the one above.
            //
            // `deleteBackward()` covers the *empty* block case, where the
            // keyboard reports no text change at all and this method never runs.
            // Both paths are needed.
            if replacement.isEmpty, range.location == 0, range.length == 0 {
                parent.onMergeBackwards()
                return false
            }

            // More than one line arriving at once is a paste, not typing: make
            // a block per paragraph instead of burying them all in this one.
            if replacement.count > 1, replacement.contains("\n") {
                let full = textView.text as NSString
                let before = full.substring(to: range.location)
                let after = full.substring(from: range.location + range.length)
                let paragraphs = replacement.components(separatedBy: .newlines)
                parent.onPasteParagraphs(before, paragraphs, after)
                return false
            }

            // Return splits the block rather than inserting a newline. A block
            // editor has no use for a line break inside a paragraph — that is
            // what the next block is for.
            guard replacement == "\n" else { return true }

            let full = textView.text as NSString
            let before = full.substring(to: range.location)
            let after = full.substring(from: range.location + range.length)
            parent.onSplit(before, after)
            return false
        }
    }
}

/// A text view that reports a backspace pressed at the very start.
///
/// `deleteBackward()` is the only reliable hook for it: the keyboard delivers no
/// text change when there is nothing to delete, so no delegate method fires.
final class InterceptingTextView: UITextView {
    /// Returns true when the press was handled and should not delete anything.
    var onDeleteBackwardAtStart: (() -> Bool)?

    let placeholderLabel = UILabel()

    override func deleteBackward() {
        if selectedRange == NSRange(location: 0, length: 0),
           onDeleteBackwardAtStart?() == true {
            return
        }
        super.deleteBackward()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        placeholderLabel.frame = CGRect(
            x: 0, y: 0,
            width: bounds.width,
            height: placeholderLabel.sizeThatFits(
                CGSize(width: bounds.width, height: .greatestFiniteMagnitude)
            ).height
        )
    }
}
