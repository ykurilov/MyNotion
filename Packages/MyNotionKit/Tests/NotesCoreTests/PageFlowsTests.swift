import Foundation
import Testing
@testable import NotesCore

/// Потоки блоков страницы (data-model.md, «Потоки»): поток страницы и потоки контейнеров вне её текста —
/// колонки, строки и столбцы таблицы, ячейки строки.
@MainActor
@Suite("Потоки блоков")
struct PageFlowsTests {
    let folder: TemporaryFolder
    let store: NotesStore
    let pageId: UUID
    /// Абзац, колонки, абзац после колонок; в колонках по два абзаца.
    let intro: UUID
    let columnList: UUID
    let leftColumn: UUID
    let rightColumn: UUID
    let leftBlocks: [UUID]
    let rightBlocks: [UUID]
    let outro: UUID

    init() throws {
        folder = try TemporaryFolder()
        store = try NotesStore(database: AppDatabase.open(at: folder.databaseURL), clock: HybridLogicalClock(deviceId: UUID()))
        let ids = try store.write { tx in
            let page = try tx.createPage(title: "Колонки")
            let first = try tx.blocks(ofPage: page.id)[0]
            var intro = first
            intro.text = InlineText("Вступление")
            try tx.updateBlock(intro)
            let list = try tx.insertBlock(Block(pageId: page.id, kind: .columnList, sortKey: .between(first.sortKey, nil)))
            let outro = try tx.insertBlock(Block(pageId: page.id, text: InlineText("После колонок"), sortKey: .between(list.sortKey, nil)))
            let left = try tx.insertBlock(Block(pageId: page.id, kind: .column, sortKey: .between(nil, nil), containerId: list.id))
            let right = try tx.insertBlock(Block(pageId: page.id, kind: .column, sortKey: .between(left.sortKey, nil), containerId: list.id))
            func fill(_ column: Block, _ texts: [String]) throws -> [UUID] {
                var key: FractionalSortKey?
                return try texts.map { text in
                    key = .between(key, nil)
                    return try tx.insertBlock(Block(pageId: page.id, text: InlineText(text), sortKey: key!, containerId: column.id)).id
                }
            }
            return (page.id, first.id, list.id, left.id, right.id, try fill(left, ["Л1", "Л2"]), try fill(right, ["П1", "П2"]), outro.id)
        }
        (pageId, intro, columnList, leftColumn, rightColumn, leftBlocks, rightBlocks, outro) = ids
    }

    func openDocument() throws -> PageDocument {
        PageDocument(content: try #require(try store.pageContent(pageId)))
    }

    @Test("blocks — только поток страницы; flow(containerId) — блоки контейнера по sortKey")
    func flowsAreSeparated() throws {
        let document = try openDocument()
        #expect(document.blocks.map(\.id) == [intro, columnList, outro])
        #expect(document.flow(columnList).map(\.id) == [leftColumn, rightColumn])
        #expect(document.flow(leftColumn).map(\.text.string) == ["Л1", "Л2"])
        #expect(document.flow(rightColumn).map(\.text.string) == ["П1", "П2"])
        #expect(document.block(leftBlocks[1])?.text.string == "Л2")
        #expect(document.index(ofBlock: leftBlocks[1]) == nil, "индекс — место в потоке страницы")
    }

    @Test("Правка в потоке колонки не трогает поток страницы")
    func editInsideColumn() throws {
        let document = try openDocument()
        let pageBefore = document.blocks
        let ids = document.replaceBlocks(in: leftColumn, after: leftBlocks[0], before: leftBlocks[1], with: [BlockDraft(id: nil, text: InlineText("Л1½"))])
        #expect(document.blocks == pageBefore)
        #expect(document.flow(leftColumn).map(\.text.string) == ["Л1", "Л1½", "Л2"])
        let inserted = try #require(document.block(ids[0]))
        #expect(inserted.containerId == leftColumn)
        #expect(document.flow(rightColumn).map(\.id) == rightBlocks)
        document.setText(InlineText("П2 правка"), ofBlock: rightBlocks[1])
        #expect(document.flow(rightColumn).last?.text.string == "П2 правка")
        #expect(document.blocks == pageBefore)
    }

    @Test("Автосохранение пишет блоки всех потоков")
    func autosaveWritesAllFlows() throws {
        let document = try openDocument()
        document.setText(InlineText("Вступление!"), ofBlock: intro)
        document.setText(InlineText("Л2!"), ofBlock: leftBlocks[1])
        let ids = document.replaceBlocks(in: rightColumn, after: rightBlocks[1], before: nil, with: [BlockDraft(id: nil, text: InlineText("П3"))])
        let autosave = AutosaveCoordinator(document: document, store: store, scheduler: ManualAutosaveScheduler())
        #expect(autosave.saveNow())
        autosave.stop()
        #expect(!document.hasUnsavedChanges)

        let stored = try #require(try store.pageContent(pageId)).blocks
        let byId = Dictionary(uniqueKeysWithValues: stored.map { ($0.id, $0) })
        #expect(byId[intro]?.text.string == "Вступление!")
        #expect(byId[leftBlocks[1]]?.text.string == "Л2!")
        #expect(byId[ids[0]]?.containerId == rightColumn)
        #expect(byId[ids[0]]?.text.string == "П3")
        #expect(PageDocument(content: try #require(try store.pageContent(pageId))).flow(rightColumn).map(\.text.string) == ["П1", "П2", "П3"])
    }

    @Test("Сирота: без контейнера — сразу за своим columnList, без него — в конце страницы; запись не меняется")
    func orphansShownInPageFlow() throws {
        // Колонку удалили на другом Mac, а в неё успели добавить блок: колонка — пометкой «удалён».
        try store.write { tx in
            try tx.markDeletedForTests(rightColumn)
        }
        let unknownContainer = UUID()
        let stray = try store.write { tx in
            try tx.insertBlock(Block(pageId: pageId, text: InlineText("Из неизвестного контейнера"), sortKey: .between(nil, nil),
                                     containerId: unknownContainer)).id
        }
        let document = try openDocument()
        #expect(document.blocks.map(\.id) == [intro, columnList] + rightBlocks + [outro, stray])
        #expect(document.flow(columnList).map(\.id) == [leftColumn])
        #expect(document.isOrphan(rightBlocks[0]) && document.isOrphan(stray))
        #expect(!document.isOrphan(outro))
        #expect(document.block(rightBlocks[0])?.containerId == rightColumn, "запись не меняется")

        // Правка текста сироты и соседей не переносит её в поток страницы.
        document.setText(InlineText("П1 правка"), ofBlock: rightBlocks[0])
        document.replaceBlocks(after: rightBlocks[1], before: outro, with: [BlockDraft(id: nil, text: InlineText("новый"))])
        let autosave = AutosaveCoordinator(document: document, store: store, scheduler: ManualAutosaveScheduler())
        #expect(autosave.saveNow())
        autosave.stop()
        let stored = Dictionary(uniqueKeysWithValues: try #require(try store.pageContent(pageId)).blocks.map { ($0.id, $0) })
        #expect(stored[rightBlocks[0]]?.containerId == rightColumn)
        #expect(stored[rightBlocks[0]]?.text.string == "П1 правка")
        #expect(stored[stray]?.containerId == unknownContainer)
        let fresh = try openDocument()
        #expect(fresh.blocks.map(\.text.string) == ["Вступление", "", "П1 правка", "П2", "новый", "После колонок", "Из неизвестного контейнера"])
    }

    @Test("Пришёл контейнер — сирота встаёт на место")
    func orphanReturnsWhenContainerArrives() throws {
        try store.write { tx in try tx.markDeletedForTests(rightColumn) }
        let document = try openDocument()
        #expect(document.isOrphan(rightBlocks[0]))
        try store.write { tx in try tx.markDeletedForTests(rightColumn, deleted: false) }
        let change = document.applyExternalChanges(try #require(try store.pageContent(pageId)), conflicts: [])
        #expect(document.blocks.map(\.id) == [intro, columnList, outro])
        #expect(document.flow(rightColumn).map(\.id) == rightBlocks)
        #expect(change.changedFlowIds.contains(rightColumn))
        #expect(change.touchesBlocks)
    }

    @Test("Удаление контейнера помечает всё внутри одной правкой")
    func removingContainerRemovesItsFlows() throws {
        let document = try openDocument()
        var edits = 0
        document.didEdit = { edits += 1 }
        document.replaceBlocks(after: intro, before: outro, with: [])
        #expect(edits == 1)
        #expect(document.blocks.map(\.id) == [intro, outro])
        #expect(document.flow(columnList).isEmpty && document.flow(leftColumn).isEmpty)
        #expect(document.block(leftBlocks[0]) == nil)

        let autosave = AutosaveCoordinator(document: document, store: store, scheduler: ManualAutosaveScheduler())
        #expect(autosave.saveNow())
        autosave.stop()
        #expect(try #require(try store.pageContent(pageId)).blocks.map(\.id) == [intro, outro])
    }

    /// Открытие страницы (T085, профиль переключения вкладок): блоки приходят из базы уже по порядку, и документ
    /// не сортирует их заново — только проверяет порядок. Общий `sortKey` (бывает после слияния правок) — худший
    /// случай: порядок решают id, и открытие 20 000 блоков с сортировкой стоило 0,35 с, с проверкой — 0,09 с
    /// (iMac, отладочная сборка).
    @Test("2 000 блоков из базы с общим sortKey — поток страницы в порядке базы")
    func storedOrderIsKept() throws {
        try checkStoredOrder(blockCount: 2_000, budget: nil)
    }

    /// Бюджет времени на 20 000 блоках — группа замеров (`MYNOTION_PERF=1`, scripts/imac/perf-tests.zsh).
    @Test("20 000 блоков из базы по порядку — поток страницы без пересортировки", .enabled(if: ProcessInfo.processInfo.environment["MYNOTION_PERF"] != nil))
    func storedOrderIsNotResortedPerformance() throws {
        try checkStoredOrder(blockCount: 20_000, budget: .milliseconds(200))
    }

    private func checkStoredOrder(blockCount: Int, budget: Duration?) throws {
        var content = try #require(try store.pageContent(pageId))
        let key = FractionalSortKey.between(nil, nil)
        content.blocks = (0..<blockCount).map { (number: Int) -> Block in
            Block(pageId: pageId, text: InlineText("Абзац \(number)"), sortKey: key)
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        let clock = ContinuousClock()
        var document: PageDocument?
        let elapsed = clock.measure { document = PageDocument(content: content) }
        if let budget { #expect(elapsed < budget, "открытие \(blockCount) блоков: \(elapsed)") }
        #expect(document?.blocks.map(\.id) == content.blocks.map(\.id))
    }

    @Test("Блоки пришли не по порядку — поток всё равно по sortKey")
    func unorderedBlocksAreSorted() throws {
        var content = try #require(try store.pageContent(pageId))
        var key: FractionalSortKey?
        let blocks = (0..<50).map { (number: Int) -> Block in
            key = .between(key, nil)
            return Block(pageId: pageId, text: InlineText("Абзац \(number)"), sortKey: key!)
        }
        content.blocks = blocks.reversed()
        #expect(PageDocument(content: content).blocks.map(\.id) == blocks.map(\.id))
    }
}

extension NotesTransaction {
    /// Пометить блок удалённым или вернуть, не трогая блоки внутри — как бывает посреди слияния правок двух Mac.
    func markDeletedForTests(_ blockId: UUID, deleted: Bool = true) throws {
        try execute(sql: "UPDATE block SET isDeleted = ? WHERE id = ?", arguments: [.integer(deleted ? 1 : 0), .text(blockId.uuidString.lowercased())])
    }
}
