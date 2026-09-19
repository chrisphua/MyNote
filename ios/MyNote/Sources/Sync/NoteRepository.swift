import Foundation
import SwiftData
import MyNoteCore

/// Every write the UI makes goes through here.
///
/// One job: stamp the edit with a fresh clock, persist it locally, queue it for
/// sync, and return — all without awaiting the network. Views call these and
/// treat them as instant, because locally they are.
@MainActor
struct NoteRepository {
    let store: SwiftDataStore
    let coordinator: SyncCoordinator

    // MARK: - Notes

    @discardableResult
    func createNote(title: String = "", parentId: String? = nil, after previous: String? = nil) async -> String {
        let id = UUID().uuidString
        let note = Note(
            id: id,
            title: title,
            parentId: parentId,
            orderKey: FractionalIndex.between(previous, nil),
            hlc: await coordinator.engine.stamp()
        )
        await write(note.asChange())

        // A brand-new page opens with one empty paragraph, so the cursor has
        // somewhere to land instead of an empty screen.
        await appendBlock(to: id, after: nil)
        return id
    }

    func rename(noteId: String, title: String, icon: String?, parentId: String?, orderKey: String) async {
        let note = Note(id: noteId, title: title, icon: icon, parentId: parentId,
                        orderKey: orderKey, hlc: await coordinator.engine.stamp())
        await write(note.asChange())
    }

    func deleteNote(_ noteId: String, blockIds: [String]) async {
        let stamp = await coordinator.engine.stamp()
        await write(Change(entity: .note, id: noteId, hlc: stamp, deleted: true))
        // Tombstone the blocks too, or they would linger on other devices.
        for blockId in blockIds {
            await write(Change(entity: .block, id: blockId,
                               hlc: await coordinator.engine.stamp(), deleted: true))
        }
    }

    // MARK: - Blocks

    @discardableResult
    func appendBlock(to noteId: String, after previous: String?, before next: String? = nil,
                     type: BlockType = .paragraph) async -> String {
        let block = Block(
            noteId: noteId,
            orderKey: FractionalIndex.between(previous, next),
            type: type,
            hlc: await coordinator.engine.stamp()
        )
        await write(block.asChange())
        return block.id
    }

    /// Return pressed: the text before the caret stays, the rest becomes a new
    /// block underneath.
    ///
    /// - Returns: the id of the new block, so the caller can move the caret into it.
    @discardableResult
    func splitBlock(_ block: Block, before: String, after: String,
                    nextOrderKey: String?) async -> String {
        var head = block
        head.content.text = before
        await update(block: head)

        let tail = Block(
            noteId: block.noteId,
            orderKey: FractionalIndex.between(block.orderKey, nextOrderKey),
            // A list carries on as a list; a heading does not, because the line
            // after a heading is almost never another heading.
            type: block.type.continuesOnSplit ? block.type : .paragraph,
            content: BlockContent(text: after),
            hlc: await coordinator.engine.stamp()
        )
        await write(tail.asChange())
        return tail.id
    }

    /// A multi-paragraph paste: one block per paragraph.
    ///
    /// Pasting an article used to drop the whole thing into a single block.
    /// A block's text view does not scroll — it grows to fit — so one block
    /// holding thousands of words has to lay every line of it out again on each
    /// keystroke, and the editor stops responding. Splitting on paste is also
    /// simply what a block editor is for: the paragraphs arrive as paragraphs,
    /// each one movable and styleable on its own.
    ///
    /// - Returns: the id of the last block written, and the caret offset within
    ///   it — the point where the pasted text ends and the block's old trailing
    ///   text resumes.
    func insertParagraphs(
        into block: Block, before: String, paragraphs: [String], after: String,
        nextOrderKey: String?
    ) async -> (blockId: String, offset: Int) {
        // A blank line between paragraphs is a separator, not a paragraph.
        var texts = paragraphs.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if texts.isEmpty { texts = [""] }

        var head = block
        head.content.text = before + texts[0]
        await update(block: head)

        guard texts.count > 1 else {
            // One paragraph after all: nothing structural, just longer text.
            let offset = head.content.text.count
            if !after.isEmpty {
                head.content.text += after
                await update(block: head)
            }
            return (block.id, offset)
        }

        var previousKey = block.orderKey
        var lastId = block.id
        var lastOffset = head.content.text.count

        for (index, text) in texts.dropFirst().enumerated() {
            let isLast = index == texts.count - 2
            let key = FractionalIndex.between(previousKey, nextOrderKey)
            let body = isLast ? text + after : text
            let paragraph = Block(
                noteId: block.noteId,
                orderKey: key,
                // Pasted prose is prose. Carrying a heading or a code style
                // across every pasted paragraph is never what was meant.
                type: block.type.continuesOnSplit ? block.type : .paragraph,
                content: BlockContent(text: body),
                hlc: await coordinator.engine.stamp()
            )
            await write(paragraph.asChange())
            previousKey = key
            lastId = paragraph.id
            if isLast { lastOffset = text.count }
        }

        return (lastId, lastOffset)
    }

    /// Backspace at the start of a block: fold it into the one above.
    ///
    /// - Returns: the caret offset in the previous block, i.e. the join point.
    @discardableResult
    func mergeIntoPrevious(_ block: Block, previous: Block) async -> Int {
        let joinOffset = previous.content.text.count

        if !block.content.text.isEmpty {
            var merged = previous
            merged.content.text += block.content.text
            await update(block: merged)
        }
        await deleteBlock(block.id)
        return joinOffset
    }

    func update(block: Block) async {
        var updated = block
        updated.hlc = await coordinator.engine.stamp()
        await write(updated.asChange())
    }

    func deleteBlock(_ blockId: String) async {
        await write(Change(entity: .block, id: blockId,
                           hlc: await coordinator.engine.stamp(), deleted: true))
    }

    /// Create the welcome note, once, on a fresh install.
    ///
    /// Guarded on the database being empty rather than on a flag alone: someone
    /// restoring a backup, or reinstalling with notes already in their Drive,
    /// should not find this sitting on top of their own writing.
    @discardableResult
    func seedWelcomeNoteIfNeeded(existingNoteCount: Int) async -> String? {
        let key = "welcome.seeded"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: key), existingNoteCount == 0 else { return nil }
        defaults.set(true, forKey: key)

        let noteId = await createNote(title: WelcomeNote.title)

        // `createNote` leaves one empty block for the cursor; the first line
        // takes it over rather than sitting under a blank.
        let firstBlockId = (try? await store.blockIds(inNote: noteId))?.first
        var previousKey: String? = nil

        for (index, line) in WelcomeNote.lines.enumerated() {
            if index == 0, let firstBlockId {
                let block = Block(id: firstBlockId, noteId: noteId,
                                  orderKey: FractionalIndex.between(nil, nil),
                                  type: line.type,
                                  content: BlockContent(text: line.text),
                                  hlc: await coordinator.engine.stamp())
                await write(block.asChange())
                previousKey = block.orderKey
                continue
            }

            let block = Block(noteId: noteId,
                              orderKey: FractionalIndex.between(previousKey, nil),
                              type: line.type,
                              content: BlockContent(text: line.text),
                              hlc: await coordinator.engine.stamp())
            await write(block.asChange())
            previousKey = block.orderKey
        }
        return noteId
    }

    // MARK: - Themes

    func saveTheme(_ spec: ThemeSpec) async {
        await write(Change(
            entity: .theme, id: spec.id,
            hlc: await coordinator.engine.stamp(), deleted: false,
            fields: ["name": .string(spec.name), "spec": .string(spec.encoded())]
        ))
    }

    private func write(_ change: Change) async {
        do {
            try await store.recordLocal(change)
        } catch {
            // Local persistence failing is serious, but the in-memory model is
            // still correct for this session, so keep the app usable.
            assertionFailure("local write failed: \(error)")
        }
        await coordinator.refreshPending()
        coordinator.scheduleSync()
    }
}
