import SwiftUI
import SwiftData
import MyNoteCore

/// The block editor.
///
/// Responsive behaviour lives here rather than in a wrapper: the content column
/// is centred and capped at the theme's `maxContentWidth`, so the same view is
/// comfortable on a 5.4" phone and doesn't stretch to unreadable line lengths on
/// a 13" iPad.
struct NoteEditorView: View {
    let noteId: String

    @Environment(AppEnvironment.self) private var app
    @Environment(ThemeManager.self) private var theme
    @Environment(\.horizontalSizeClass) private var sizeClass

    @Query private var notes: [NoteEntity]
    @Query private var blocks: [BlockEntity]

    /// A plain binding, not `@FocusState`: focus is driven into `BlockTextView`,
    /// which manages first responder itself so it can also place the caret.
    @State private var focusedBlock: String?
    @State private var caret: CaretRequest?

    init(noteId: String) {
        self.noteId = noteId
        _notes = Query(filter: #Predicate<NoteEntity> { $0.id == noteId })
        // Sorted in Swift below, not here — see `ordered`.
        _blocks = Query(filter: #Predicate<BlockEntity> { $0.noteId == noteId && !$0.deleted })
    }

    private var note: NoteEntity? { notes.first }

    /// Blocks in reading order.
    ///
    /// Sorted here rather than by the `@Query`, because a fractional index is
    /// only meaningful under **code-point** comparison — `"V" < "k"` — and the
    /// store's collation is not that. `@Query` returned a split block *above*
    /// its own parent, while the identical records fetched through a
    /// `ModelContext` came back correctly, so the ordering cannot be left to the
    /// store. Swift's `<` on `String` is the comparison the index is defined in.
    private var ordered: [BlockEntity] {
        blocks.sorted { $0.orderKey < $1.orderKey }
    }
    private var repository: NoteRepository {
        NoteRepository(store: app.store, coordinator: app.syncCoordinator)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.current.blockSpacing) {
                titleField
                ForEach(ordered) { block in
                    BlockRowView(
                        block: block,
                        focusedBlockId: $focusedBlock,
                        caret: $caret,
                        onCommit: { updated in Task { await repository.update(block: updated) } },
                        onSplit: { before, after in
                            Task { await split(block, before: before, after: after) }
                        },
                        onMergeBackwards: { Task { await mergeBackwards(from: block) } },
                        onDelete: { await removeBlock(block) },
                        onChangeType: { type in await changeType(block, to: type) }
                    )
                }

                // Tapping the empty space below the last block starts a new one,
                // the way a paper page lets you keep writing.
                Color.clear
                    .frame(height: 120)
                    .contentShape(Rectangle())
                    .onTapGesture { Task { await appendAtEnd() } }
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, theme.current.contentPadding)
            .frame(maxWidth: theme.current.maxContentWidth)
            .frame(maxWidth: .infinity)   // centres the capped column
        }
        .background(theme.current.background)
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(note?.title.isEmpty == false ? note!.title : "Untitled")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            // Only while something is being edited. A formatting bar with
            // nothing to format is just a strip of chrome.
            if let id = focusedBlock, let block = ordered.first(where: { $0.id == id }) {
                BlockFormatBar(
                    current: BlockType(rawValue: block.type) ?? .paragraph,
                    onSelect: { type in Task { await changeType(block, to: type) } },
                    onDone: { focusedBlock = nil }
                )
            }
        }
    }

    /// Phones get tighter margins; regular-width devices can afford the theme's.
    private var horizontalPadding: CGFloat {
        sizeClass == .compact
            ? min(theme.current.contentPadding, 16)
            : theme.current.contentPadding * 1.5
    }

    private var titleField: some View {
        TextField("Untitled", text: Binding(
            get: { note?.title ?? "" },
            set: { newValue in
                guard let note else { return }
                note.title = newValue
                Task {
                    await repository.rename(noteId: note.id, title: newValue, icon: note.icon,
                                            parentId: note.parentId, orderKey: note.orderKey)
                }
            }
        ), axis: .vertical)
        .font(theme.current.font(.heading1))
        .foregroundStyle(theme.current.textPrimary)
        .textFieldStyle(.plain)
        .padding(.bottom, 8)
    }

    // MARK: - Editing

    private func appendAtEnd() async {
        let id = await repository.appendBlock(to: noteId, after: ordered.last?.orderKey)
        focusedBlock = id
        caret = .end(of: id)
    }

    /// Return: the text after the caret moves into a new block below.
    private func split(_ block: BlockEntity, before: String, after: String) async {
        guard let domain = block.asDomain else { return }
        let next = ordered.first { $0.orderKey > block.orderKey }?.orderKey
        let id = await repository.splitBlock(domain, before: before, after: after,
                                             nextOrderKey: next)
        focusedBlock = id
        // Typing continues at the start of what was carried down.
        caret = CaretRequest(blockId: id, offset: 0)
    }

    /// Backspace at the start: fold this block into the one above it.
    private func mergeBackwards(from block: BlockEntity) async {
        guard let previous = ordered.last(where: { $0.orderKey < block.orderKey }) else {
            // Already the first block. Backspacing out of a list or heading turns
            // it back into plain text, which is the usual way out of a style you
            // did not mean to apply.
            if let domain = block.asDomain, domain.type != .paragraph {
                await changeType(block, to: .paragraph)
            }
            return
        }
        guard let domain = block.asDomain, let previousDomain = previous.asDomain else { return }

        let joinOffset = await repository.mergeIntoPrevious(domain, previous: previousDomain)
        focusedBlock = previous.id
        caret = CaretRequest(blockId: previous.id, offset: joinOffset)
    }

    private func removeBlock(_ block: BlockEntity) async {
        // Never leave a note with zero blocks — there would be nowhere to type.
        guard ordered.count > 1 else { return }
        let previous = ordered.last { $0.orderKey < block.orderKey }
        await repository.deleteBlock(block.id)
        focusedBlock = previous?.id
        if let previous { caret = .end(of: previous.id) }
    }

    private func changeType(_ block: BlockEntity, to type: BlockType) async {
        guard var domain = block.asDomain else { return }
        domain.type = type
        await repository.update(block: domain)
    }
}

extension BlockEntity {
    var asDomain: Block? {
        guard let type = BlockType(rawValue: type) else { return nil }
        return Block(id: id, noteId: noteId, parentId: parentId, orderKey: orderKey,
                     type: type, content: BlockContent.decode(content),
                     hlc: hlc, deleted: deleted)
    }
}

extension BlockType {
    var label: String {
        switch self {
        case .paragraph: "Text"
        case .heading1:  "Heading 1"
        case .heading2:  "Heading 2"
        case .heading3:  "Heading 3"
        case .todo:      "To-do"
        case .bullet:    "Bulleted list"
        case .numbered:  "Numbered list"
        case .quote:     "Quote"
        case .code:      "Code"
        case .divider:   "Divider"
        case .image:     "Image"
        }
    }

    var symbol: String {
        switch self {
        case .paragraph: "text.alignleft"
        case .heading1:  "textformat.size.larger"
        case .heading2:  "textformat.size"
        case .heading3:  "textformat.size.smaller"
        case .todo:      "checklist"
        case .bullet:    "list.bullet"
        case .numbered:  "list.number"
        case .quote:     "text.quote"
        case .code:      "chevron.left.forwardslash.chevron.right"
        case .divider:   "minus"
        case .image:     "photo"
        }
    }
}
