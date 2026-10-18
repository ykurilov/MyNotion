import Foundation
import Testing
@testable import NotesCore
@testable import Sync

/// Правка с другого Mac приходит в страницу, открытую на этом (research R4, R5): появляется в документе,
/// не трогает набираемый блок и не затирается автосохранением.
@MainActor
@Suite("Пришедшие правки в открытой странице")
struct OpenDocumentRemoteApplyTests {
    let numbering = TestJournalNumbering()
    let a: SyncTestMac
    let b: SyncTestMac
    let pageId: UUID
    let blockIds: [UUID]

    init() throws {
        a = try SyncTestMac(name: "Mac A", wallMillis: 10_000)
        b = try SyncTestMac(name: "Mac B", wallMillis: 10_000)
        let shared = try sharedPage(on: a, others: [b], numbering: numbering, text: "первый")
        let more = try a.store.write { tx in
            let first = try #require(try tx.block(shared.block))
            let second = try tx.insertBlock(Block(pageId: shared.page, text: InlineText("второй"), sortKey: .between(first.sortKey, nil)))
            let third = try tx.insertBlock(Block(pageId: shared.page, text: InlineText("третий"), sortKey: .between(second.sortKey, nil)))
            return [second.id, third.id]
        }
        try exchange([a, b], numbering: numbering)
        pageId = shared.page
        blockIds = [shared.block] + more
    }

    @Test("Правка чужого блока появляется в открытом документе; остальные блоки и их порядок не трогаются")
    func remoteEditOfOtherBlockAppears() throws {
        let document = try b.documents.open(pageId)
        var reported: [PageDocument.ExternalChange] = []
        let observer = NotificationCenter.default.addObserver(
            forName: PageDocument.didApplyExternalChanges, object: document, queue: nil
        ) { note in
            if let change = note.userInfo?[PageDocument.externalChangeKey] as? PageDocument.ExternalChange { reported.append(change) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        a.wall.set(30_000)
        try a.setText("второй, поправленный на A", ofBlock: blockIds[1])
        try exchange([a, b], numbering: numbering)

        #expect(document.blocks.map(\.id) == blockIds)
        #expect(document.blocks.map(\.text.string) == ["первый", "второй, поправленный на A", "третий"])
        #expect(!document.hasUnsavedChanges, "Пришедшее уже в базе — писать нечего")
        #expect(reported.count == 1)
        #expect(reported.first?.changedBlockIds == [blockIds[1]], "Редактор перерисует только этот блок")
        #expect(reported.first?.insertedBlockIds.isEmpty == true)
        #expect(reported.first?.removedBlockIds.isEmpty == true)
    }

    @Test("Набранное, но ещё не записанное в другом блоке остаётся, а пришедшая правка появляется рядом")
    func unsavedTypingInAnotherBlockSurvives() throws {
        let document = try b.documents.open(pageId)
        b.wall.set(20_000)
        document.setText(InlineText("первый, набираю"), ofBlock: blockIds[0])

        a.wall.set(30_000)
        try a.setText("третий с A", ofBlock: blockIds[2])
        try exchange([a, b], numbering: numbering)

        #expect(document.blocks.map(\.text.string) == ["первый, набираю", "второй", "третий с A"])
        try exchange([a, b], numbering: numbering)
        for mac in [a, b] {
            #expect(try mac.blocks(pageId).map(\.text.string) == ["первый, набираю", "второй", "третий с A"], "\(mac.name)")
            #expect(try mac.conflicts().isEmpty)
        }
    }

    @Test("Правка блока, который сейчас набирается, становится конфликтом: набранное на экране, обе версии целы")
    func remoteEditOfTypedBlockBecomesConflict() throws {
        let document = try b.documents.open(pageId)
        a.wall.set(30_000)
        try a.setText("второй с A", ofBlock: blockIds[1])
        b.wall.set(40_000)
        document.setText(InlineText("второй, набираю на B"), ofBlock: blockIds[1])

        try exchange([a, b], numbering: numbering)

        #expect(document.blocks[1].text.string == "второй, набираю на B", "Набранное не исчезло с экрана")
        let conflict = try #require(try b.conflicts().first)
        #expect(conflict.blockId == blockIds[1])
        #expect(Set([conflict.localVersion.string, conflict.remoteVersion.string]) == ["второй с A", "второй, набираю на B"])
        #expect(document.pendingConflicts.map(\.blockId) == [blockIds[1]], "Метка «Две версии» видна в открытой странице")
    }

    @Test("Последующее автосохранение не затирает пришедшую правку")
    func autosaveDoesNotOverwriteRemoteEdit() throws {
        let document = try b.documents.open(pageId)
        a.wall.set(30_000)
        try a.setText("второй с A", ofBlock: blockIds[1])
        try exchange([a, b], numbering: numbering)

        b.wall.set(40_000)
        document.setText(InlineText("третий, правлю после"), ofBlock: blockIds[2])
        b.scheduler.advance(by: .seconds(1))
        b.documents.saveAll()

        #expect(try b.blocks(pageId).map(\.text.string) == ["первый", "второй с A", "третий, правлю после"])
        #expect(try b.conflicts().isEmpty)
    }

    @Test("Пришедшие новый блок и удаление блока появляются в открытом документе на своих местах")
    func remoteInsertAndDeleteAppear() throws {
        let document = try b.documents.open(pageId)
        a.wall.set(30_000)
        let inserted = try a.store.write { tx in
            let first = try #require(try tx.block(blockIds[0]))
            let second = try #require(try tx.block(blockIds[1]))
            try tx.deleteBlock(blockIds[2])
            return try tx.insertBlock(Block(pageId: pageId, text: InlineText("новый между"), sortKey: .between(first.sortKey, second.sortKey))).id
        }
        try exchange([a, b], numbering: numbering)

        #expect(document.blocks.map(\.id) == [blockIds[0], inserted, blockIds[1]])
        #expect(document.blocks.map(\.text.string) == ["первый", "новый между", "второй"])
    }

    @Test("Пришедшее новое название показывается, если своё название сейчас не правится")
    func remoteTitleAppears() throws {
        let document = try b.documents.open(pageId)
        a.wall.set(30_000)
        try a.rename(pageId, "Название с A")
        try exchange([a, b], numbering: numbering)
        #expect(document.page.title == "Название с A")
    }
}
