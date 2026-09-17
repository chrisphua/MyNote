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

    func update(block: Block) async {
        var updated = block
        updated.hlc = await coordinator.engine.stamp()
        await write(updated.asChange())
    }

    func deleteBlock(_ blockId: String) async {
        await write(Change(entity: .block, id: blockId,
                           hlc: await coordinator.engine.stamp(), deleted: true))
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
            try await store.enqueue(change)
        } catch {
            // Local persistence failing is serious, but the in-memory model is
            // still correct for this session, so keep the app usable.
            assertionFailure("local write failed: \(error)")
        }
        await coordinator.refreshPendingCount()
        coordinator.scheduleSync()
    }
}
