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

    /// The title's own copy, for the same reason every block keeps one.
    @State private var title: String = ""
    @State private var titleLoaded = false
    @State private var titleWriteTask: Task<Void, Never>?
    @FocusState private var titleFocused: Bool

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
        ScrollViewReader { proxy in
            editorScroll(proxy)
        }
    }

    private func editorScroll(_ proxy: ScrollViewProxy) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: theme.current.blockSpacing) {
                titleField
                ForEach(ordered) { block in
                    BlockRowView(
                        block: block,
                        focusedBlockId: $focusedBlock,
                        caret: $caret,
                        onCommit: { updated in Task { await repository.update(block: updated) } },
                        onPasteParagraphs: { before, paragraphs, after in
                            Task { await paste(into: block, before: before,
                                               paragraphs: paragraphs, after: after) }
                        },
                        onSplit: { before, after in
                            Task { await split(block, before: before, after: after) }
                        },
                        onMergeBackwards: { Task { await mergeBackwards(from: block) } },
                        onDelete: { await removeBlock(block) },
                        onChangeType: { type in await changeType(block, to: type) }
                    )
                    .id(block.id)
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
        // The stack is lazy, so a block outside the rendered window does not
        // exist yet and cannot take focus. Anything that aims the caret has to
        // bring the target into view first, or a split near the end of a long
        // note types into the block above instead. A nil anchor scrolls the
        // least amount needed, so a caret already on screen does not jump.
        .onChange(of: caret) { _, request in
            guard let request else { return }
            proxy.scrollTo(request.blockId, anchor: nil)
        }
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

    /// The note's title.
    ///
    /// Bound to local state, not straight to the store. Binding it to the model
    /// meant every keystroke was written, re-read and handed back to the field,
    /// which reset its contents and put the caret at the end — so after pasting
    /// a title, a word could only ever be added after the last character.
    /// The block fields already worked this way; the title was missed.
    private var titleField: some View {
        TextField("Untitled", text: $title, axis: .vertical)
            .font(theme.current.font(.heading1))
            .foregroundStyle(theme.current.textPrimary)
            .textFieldStyle(.plain)
            .padding(.bottom, 8)
            .focused($titleFocused)
            .onAppear {
                guard !titleLoaded else { return }
                title = note?.title ?? ""
                titleLoaded = true
            }
            .onChange(of: title) { _, newValue in scheduleRename(to: newValue) }
            .onChange(of: note?.title) { _, incoming in
                // While it is being typed in, the field owns its text.
                guard !titleFocused, let incoming, incoming != title else { return }
                title = incoming
            }
            .onChange(of: titleFocused) { _, focused in
                if !focused { flushRename() }
            }
            .onDisappear { flushRename() }
    }

    /// Coalesces a run of keystrokes into one rename, as blocks do.
    private func scheduleRename(to newValue: String) {
        titleWriteTask?.cancel()
        titleWriteTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await rename(to: newValue)
        }
    }

    private func flushRename() {
        guard let pending = titleWriteTask else { return }
        pending.cancel()
        titleWriteTask = nil
        let newValue = title
        Task { await rename(to: newValue) }
    }

    private func rename(to newValue: String) async {
        guard let note else { return }
        note.title = newValue
        await repository.rename(noteId: note.id, title: newValue, icon: note.icon,
                                parentId: note.parentId, orderKey: note.orderKey)
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

    /// The nearest block above that actually renders a text field.
    ///
    /// A divider holds no text, so folding a block into one would put the words
    /// somewhere the writer can never reach them again — and they would still
    /// sync to the backup like that. Android crashed outright on the same
    /// mistake; here it fails quietly, which is worse.
    private func textBlock(above block: BlockEntity) -> BlockEntity? {
        ordered.last { $0.orderKey < block.orderKey && $0.type != BlockType.divider.rawValue }
    }

    /// A multi-paragraph paste becomes one block per paragraph.
    private func paste(into block: BlockEntity, before: String,
                       paragraphs: [String], after: String) async {
        guard let domain = block.asDomain else { return }
        let next = ordered.first { $0.orderKey > block.orderKey }?.orderKey
        let landing = await repository.insertParagraphs(
            into: domain, before: before, paragraphs: paragraphs,
            after: after, nextOrderKey: next
        )
        focusedBlock = landing.blockId
        caret = CaretRequest(blockId: landing.blockId, offset: landing.offset)
    }

    /// Backspace at the start: fold this block into the one above it.
    private func mergeBackwards(from block: BlockEntity) async {
        guard let previous = textBlock(above: block) else {
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
        let previous = textBlock(above: block)
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
