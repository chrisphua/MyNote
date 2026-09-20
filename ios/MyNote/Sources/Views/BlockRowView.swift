import SwiftUI
import MyNoteCore

/// One editable block.
///
/// Every variant renders through the theme, never a hard-coded colour or size —
/// that is what makes "fully customisable" true rather than approximate.
struct BlockRowView: View {
    let block: BlockEntity
    @Binding var focusedBlockId: String?
    @Binding var caret: CaretRequest?

    let onCommit: (Block) -> Void
    /// The selection inside this block moved, so the toolbar can follow it.
    let onSelectionChange: (NSRange) -> Void
    let onPasteParagraphs: (String, [String], String) -> Void
    /// Return pressed, carrying the text either side of the caret.
    let onSplit: (String, String) -> Void
    /// Backspace pressed with the caret at the very start.
    let onMergeBackwards: () -> Void
    let onDelete: () async -> Void
    let onChangeType: (BlockType) async -> Void

    @Environment(ThemeManager.self) private var theme
    @State private var text: String = ""
    @State private var spans: [Span] = []
    @State private var didLoad = false
    /// Coalesces keystrokes into one write. See `commit(text:content:)`.
    @State private var writeTask: Task<Void, Never>?

    private var isFocused: Bool { focusedBlockId == block.id }
    private var type: BlockType { BlockType(rawValue: block.type) ?? .paragraph }
    private var content: BlockContent { BlockContent.decode(block.content) }

    var body: some View {
        Group {
            switch type {
            case .divider:
                Divider().overlay(theme.current.border).padding(.vertical, 8)
            case .image:
                imagePlaceholder
            default:
                editableRow
            }
        }
        .onAppear {
            guard !didLoad else { return }
            text = content.text
            spans = content.inlineSpans
            didLoad = true
        }
        .onChange(of: block.content) { _, newValue in
            let incoming = BlockContent.decode(newValue).text

            // Ownership, not content matching, decides this.
            //
            // While the field has focus it owns its text, and `BlockTextView`
            // refuses to write anything into it — so a stale write coming back
            // from the store can no longer reach the screen. Once focus leaves,
            // the store is authoritative and whatever it says is correct.
            //
            // The exception is a structural edit: after a merge the block above
            // gains focus *and* needs the folded-up text, so a caret aimed here
            // by the editor overrides the focus rule.
            let isStructuralTarget = caret?.blockId == block.id

            // Formatting is not text. A toolbar press changes the spans and
            // leaves the words alone, and the ownership rule exists to protect
            // the words — so when the text matches, the formatting is safe to
            // take even while this block is being edited. Without this, bolding
            // a word highlighted the button and changed nothing on screen.
            if incoming == text {
                let incomingSpans = BlockContent.decode(newValue).inlineSpans
                if incomingSpans != spans { spans = incomingSpans }
                return
            }

            guard !isFocused || isStructuralTarget else { return }

            text = incoming
            spans = BlockContent.decode(newValue).inlineSpans
        }
        .onChange(of: isFocused) { _, nowFocused in
            if !nowFocused { flush() }
        }
        .onDisappear { flush() }
    }

    private var editableRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            marker
            BlockTextView(
                text: $text,
                spans: $spans,
                focusedBlockId: $focusedBlockId,
                caret: $caret,
                blockId: block.id,
                placeholder: placeholder,
                font: theme.current.uiFont(fontRole),
                textColor: UIColor(type == .quote ? theme.current.textSecondary : theme.current.textPrimary),
                placeholderColor: UIColor(theme.current.textSecondary),
                tintColor: UIColor(theme.current.accentColor),
                lineSpacing: theme.current.lineSpacing,
                onSplit: onSplit,
                onMergeBackwards: onMergeBackwards,
                onPasteParagraphs: onPasteParagraphs,
                onSelectionChange: onSelectionChange
            )
            .onChange(of: text) { _, newValue in commit(text: newValue) }
            .onChange(of: spans) { _, _ in commit(text: text) }
        }
        .padding(type == .code ? 10 : 0)
        .background(type == .code ? theme.current.codeBackground : .clear)
        .clipShape(RoundedRectangle(cornerRadius: type == .code ? theme.current.cornerRadius : 0))
        .overlay(alignment: .leading) {
            if type == .quote {
                Rectangle()
                    .fill(theme.current.accentColor)
                    .frame(width: 3)
                    .offset(x: -10)
            }
        }
        .contextMenu {
            ForEach(BlockType.allCases, id: \.self) { candidate in
                Button {
                    Task { await onChangeType(candidate) }
                } label: {
                    Label(candidate.label, systemImage: candidate.symbol)
                }
            }
            Divider()
            Button(role: .destructive) {
                Task { await onDelete() }
            } label: {
                Label("Delete block", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private var marker: some View {
        switch type {
        case .todo:
            Button {
                var updated = content
                updated.checked = !(updated.checked ?? false)
                commit(text: text, content: updated)
            } label: {
                Image(systemName: (content.checked ?? false) ? "checkmark.square.fill" : "square")
                    .foregroundStyle(theme.current.accentColor)
            }
            .buttonStyle(.plain)
            .accessibilityLabel((content.checked ?? false) ? "Completed" : "Not completed")
        case .bullet:
            Text("•").foregroundStyle(theme.current.textSecondary).font(font)
        case .numbered:
            Text("1.").foregroundStyle(theme.current.textSecondary).font(font)
        default:
            EmptyView()
        }
    }

    private var imagePlaceholder: some View {
        RoundedRectangle(cornerRadius: theme.current.cornerRadius)
            .fill(theme.current.surface)
            .frame(height: 160)
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: "photo")
                    Text("Image").font(theme.current.font(.caption))
                }
                .foregroundStyle(theme.current.textSecondary)
            }
    }

    private var fontRole: Theme.FontRole {
        switch type {
        case .heading1: .heading1
        case .heading2: .heading2
        case .heading3: .heading3
        case .code:     .code
        default:        .body
        }
    }

    private var font: Font { theme.current.font(fontRole) }

    /// Prompt shown in an empty block.
    ///
    /// A plain paragraph shows nothing. An empty page that says "Type
    /// something…" is telling the writer what they already came to do, and it
    /// sits there on every blank line of a long note.
    ///
    /// The others stay because they name a block type that is otherwise
    /// invisible when empty — an empty heading and an empty quote look alike.
    private var placeholder: String {
        switch type {
        case .heading1, .heading2, .heading3: "Heading"
        case .todo: "To-do"
        case .code: "Code"
        case .quote: "Quote"
        default: ""
        }
    }

    /// Saves the block, coalescing a run of keystrokes into one write.
    ///
    /// Writing on every keystroke meant that every character typed re-encoded
    /// the whole block to JSON, wrote it to the store, and ran a pending-changes
    /// query. That is unnoticeable in a one-line block and crippling in a large
    /// one: after pasting an article into a block, a single keypress took the
    /// best part of a second on a Mac, and far longer on a phone.
    ///
    /// The decode is inside the task for the same reason — it ran per keystroke
    /// too, on the whole block.
    ///
    /// This still honours "an edit is saved locally and the user moves on": the
    /// delay is shorter than a pause between words, and `flush()` forces the
    /// write out the moment focus leaves the block or the row goes away, so no
    /// edit can be left sitting in a timer.
    private func commit(text newText: String, content override: BlockContent? = nil) {
        writeTask?.cancel()
        writeTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            write(text: newText, content: override)
        }
    }

    /// Writes any coalesced edit immediately.
    private func flush() {
        guard let pending = writeTask else { return }
        pending.cancel()
        writeTask = nil
        write(text: text)
    }

    private func write(text newText: String, content override: BlockContent? = nil) {
        guard var domain = block.asDomain else { return }
        var updated = override ?? domain.content
        updated.text = newText
        updated.inlineSpans = InlineSpans.normalized(spans, textLength: (newText as NSString).length)
        domain.content = updated
        onCommit(domain)
    }
}
