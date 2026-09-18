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
    /// Return pressed, carrying the text either side of the caret.
    let onSplit: (String, String) -> Void
    /// Backspace pressed with the caret at the very start.
    let onMergeBackwards: () -> Void
    let onDelete: () async -> Void
    let onChangeType: (BlockType) async -> Void

    @Environment(ThemeManager.self) private var theme
    @State private var text: String = ""
    @State private var didLoad = false

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
            guard !isFocused || isStructuralTarget else { return }
            guard incoming != text else { return }

            text = incoming
        }
    }

    private var editableRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            marker
            BlockTextView(
                text: $text,
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
                onMergeBackwards: onMergeBackwards
            )
            .onChange(of: text) { _, newValue in commit(text: newValue) }
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

    private func commit(text newText: String, content override: BlockContent? = nil) {
        guard var domain = block.asDomain else { return }
        var updated = override ?? domain.content
        updated.text = newText
        domain.content = updated
        onCommit(domain)
    }
}
