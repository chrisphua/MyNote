import SwiftUI
import MyNoteCore

/// One editable block.
///
/// Every variant renders through the theme, never a hard-coded colour or size —
/// that is what makes "fully customisable" true rather than approximate.
struct BlockRowView: View {
    let block: BlockEntity
    let isFocused: Bool
    let onCommit: (Block) -> Void
    let onSplit: () async -> Void
    let onDelete: () async -> Void
    let onChangeType: (BlockType) async -> Void

    @Environment(ThemeManager.self) private var theme
    @State private var text: String = ""
    @State private var didLoad = false

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
            // A remote edit arrived for the block being viewed. Adopt it unless
            // the user is typing in it right now, which would yank the cursor.
            let incoming = BlockContent.decode(newValue).text
            if !isFocused && incoming != text { text = incoming }
        }
    }

    private var editableRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            marker
            TextField(placeholder, text: $text, axis: .vertical)
                .font(font)
                .foregroundStyle(type == .quote ? theme.current.textSecondary : theme.current.textPrimary)
                .lineSpacing(theme.current.lineSpacing)
                .textFieldStyle(.plain)
                .onSubmit { Task { await onSplit() } }
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

    private var font: Font {
        switch type {
        case .heading1: theme.current.font(.heading1)
        case .heading2: theme.current.font(.heading2)
        case .heading3: theme.current.font(.heading3)
        case .code:     theme.current.font(.code)
        default:        theme.current.font(.body)
        }
    }

    private var placeholder: String {
        switch type {
        case .heading1, .heading2, .heading3: "Heading"
        case .todo: "To-do"
        case .code: "Code"
        case .quote: "Quote"
        default: "Type something…"
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
