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

    @FocusState private var focusedBlock: String?
    @State private var showingBlockMenu = false

    init(noteId: String) {
        self.noteId = noteId
        _notes = Query(filter: #Predicate<NoteEntity> { $0.id == noteId })
        _blocks = Query(
            filter: #Predicate<BlockEntity> { $0.noteId == noteId && !$0.deleted },
            sort: [SortDescriptor(\BlockEntity.orderKey)]
        )
    }

    private var note: NoteEntity? { notes.first }
    private var repository: NoteRepository {
        NoteRepository(store: app.store, coordinator: app.syncCoordinator)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.current.blockSpacing) {
                titleField
                ForEach(blocks) { block in
                    BlockRowView(
                        block: block,
                        isFocused: focusedBlock == block.id,
                        onCommit: { updated in Task { await repository.update(block: updated) } },
                        onSplit: { await splitBlock(after: block) },
                        onDelete: { await removeBlock(block) },
                        onChangeType: { type in await changeType(block, to: type) }
                    )
                    .focused($focusedBlock, equals: block.id)
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
        .toolbar { editorToolbar }
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

    @ToolbarContentBuilder
    private var editorToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .keyboard) {
            // Block-type shortcuts sit on the keyboard bar, so changing a line
            // to a heading never requires leaving the keyboard.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(BlockType.allCases, id: \.self) { type in
                        Button {
                            guard let id = focusedBlock,
                                  let block = blocks.first(where: { $0.id == id }) else { return }
                            Task { await changeType(block, to: type) }
                        } label: {
                            Label(type.label, systemImage: type.symbol)
                                .labelStyle(.iconOnly)
                        }
                        .accessibilityLabel(type.label)
                    }
                }
            }
            Spacer()
            Button("Done") { focusedBlock = nil }
        }
    }

    // MARK: - Editing

    private func appendAtEnd() async {
        let id = await repository.appendBlock(to: noteId, after: blocks.last?.orderKey)
        focusedBlock = id
    }

    private func splitBlock(after block: BlockEntity) async {
        let next = blocks.first { $0.orderKey > block.orderKey }?.orderKey
        let id = await repository.appendBlock(to: noteId, after: block.orderKey, before: next)
        focusedBlock = id
    }

    private func removeBlock(_ block: BlockEntity) async {
        // Never leave a note with zero blocks — there would be nowhere to type.
        guard blocks.count > 1 else { return }
        let previous = blocks.last { $0.orderKey < block.orderKey }
        await repository.deleteBlock(block.id)
        focusedBlock = previous?.id
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
