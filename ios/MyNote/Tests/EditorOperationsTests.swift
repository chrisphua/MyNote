import Foundation
import Testing
import SwiftData
@testable import MyNote
import MyNoteCore

/// Split and merge at the repository level.
///
/// Separates "does the editing logic work" from "did the keyboard event get
/// delivered", which a UI test alone cannot tell apart.
@MainActor
@Suite("Editor operations")
struct EditorOperationsTests {

    /// An isolated stack: in-memory store, no folder connected, nothing shared.
    private func makeFixture() throws -> (SwiftDataStore, NoteRepository, ModelContext) {
        let schema = Schema([NoteEntity.self, BlockEntity.self, ThemeEntity.self,
                             RemoteVersion.self, SyncMeta.self])
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema,
                                               isStoredInMemoryOnly: true,
                                               cloudKitDatabase: .none)
        )
        let store = SwiftDataStore(modelContainer: container)
        let coordinator = SyncCoordinator(store: store, googleAuth: GoogleAuth(clientId: ""))
        return (store, NoteRepository(store: store, coordinator: coordinator), ModelContext(container))
    }

    /// Blocks in reading order.
    ///
    /// Sorted in Swift, not by the fetch: a fractional index is only meaningful
    /// under code-point comparison, and the store's collation is not that. This
    /// helper originally trusted `SortDescriptor` and returned a split block
    /// above its own parent — the same fault the views had.
    private func blocks(in context: ModelContext, noteId: String) throws -> [BlockEntity] {
        try context
            .fetch(FetchDescriptor<BlockEntity>(
                predicate: #Predicate { $0.noteId == noteId && !$0.deleted }
            ))
            .sorted { $0.orderKey < $1.orderKey }
    }

    @Test("a new note starts with one empty block")
    func newNoteHasOneBlock() async throws {
        let (_, repository, context) = try makeFixture()
        let noteId = await repository.createNote()

        #expect(try blocks(in: context, noteId: noteId).count == 1)
    }

    @Test("Return splits a block, carrying the tail into a new one")
    func splitCarriesTheTail() async throws {
        let (_, repository, context) = try makeFixture()
        let noteId = await repository.createNote()

        var first = try #require(try blocks(in: context, noteId: noteId).first?.asDomain)
        first.content.text = "onetwo"
        await repository.update(block: first)

        await repository.splitBlock(first, before: "one", after: "two", nextOrderKey: nil)

        let result = try blocks(in: context, noteId: noteId)
        #expect(result.count == 2)
        #expect(BlockContent.decode(result[0].content).text == "one")
        #expect(BlockContent.decode(result[1].content).text == "two")
    }

    @Test("backspace at the start removes an empty block")
    func mergeRemovesEmptyBlock() async throws {
        let (_, repository, context) = try makeFixture()
        let noteId = await repository.createNote()

        let first = try #require(try blocks(in: context, noteId: noteId).first?.asDomain)
        await repository.splitBlock(first, before: "kept", after: "", nextOrderKey: nil)

        let two = try blocks(in: context, noteId: noteId)
        #expect(two.count == 2)

        let previous = try #require(two[0].asDomain)
        let empty = try #require(two[1].asDomain)
        await repository.mergeIntoPrevious(empty, previous: previous)

        let result = try blocks(in: context, noteId: noteId)
        #expect(result.count == 1, "the empty block should be gone")
        #expect(BlockContent.decode(result[0].content).text == "kept")
    }

    @Test("backspace at the start folds text into the block above")
    func mergeJoinsText() async throws {
        let (_, repository, context) = try makeFixture()
        let noteId = await repository.createNote()

        let first = try #require(try blocks(in: context, noteId: noteId).first?.asDomain)
        await repository.splitBlock(first, before: "one", after: "two", nextOrderKey: nil)

        let two = try blocks(in: context, noteId: noteId)
        let previous = try #require(two[0].asDomain)
        let second = try #require(two[1].asDomain)

        let joinOffset = await repository.mergeIntoPrevious(second, previous: previous)

        let result = try blocks(in: context, noteId: noteId)
        #expect(result.count == 1)
        #expect(BlockContent.decode(result[0].content).text == "onetwo", "nothing should be lost")
        #expect(joinOffset == 3, "the caret belongs where the two met")
    }

    @Test("a list carries on when split; a heading does not")
    func splitKeepsListTypes() async throws {
        let (_, repository, context) = try makeFixture()
        let noteId = await repository.createNote()

        var bullet = try #require(try blocks(in: context, noteId: noteId).first?.asDomain)
        bullet.type = .bullet
        await repository.update(block: bullet)
        await repository.splitBlock(bullet, before: "a", after: "b", nextOrderKey: nil)

        var result = try blocks(in: context, noteId: noteId)
        #expect(result[1].type == BlockType.bullet.rawValue)

        var heading = try #require(result[0].asDomain)
        heading.type = .heading1
        await repository.update(block: heading)
        await repository.splitBlock(heading, before: "title", after: "body",
                                    nextOrderKey: result[1].orderKey)

        result = try blocks(in: context, noteId: noteId)
        #expect(result[1].type == BlockType.paragraph.rawValue,
                "the line after a heading is not another heading")
    }
}
