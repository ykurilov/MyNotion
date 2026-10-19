import Foundation
import Testing
@testable import NotesCore
@testable import Sync

/// Таблицы и колонки на двух Mac (research R3): ячейки, строки, столбцы и колонки — обычные блоки; правки
/// делаются теми же правками документа, что у редактора (`TableGrid`, `ColumnLayout`), и сходятся.
@MainActor
@Suite("Таблицы и колонки на двух Mac")
struct TablesColumnsConvergenceTests {
    let numbering = TestJournalNumbering()
    let a: SyncTestMac
    let b: SyncTestMac

    init() throws {
        a = try SyncTestMac(name: "Mac A", wallMillis: 10_000)
        b = try SyncTestMac(name: "Mac B", wallMillis: 10_000)
    }

    /// Открыть страницу на Mac, править документ и записать, как редактор.
    private func edit(_ mac: SyncTestMac, _ pageId: UUID, _ body: (PageDocument) throws -> Void) throws {
        let document = PageDocument(content: try #require(try mac.store.pageContent(pageId)))
        try body(document)
        let autosave = AutosaveCoordinator(document: document, store: mac.store, scheduler: mac.scheduler)
        #expect(autosave.saveNow())
        autosave.stop()
    }

    private func document(_ mac: SyncTestMac, _ pageId: UUID) throws -> PageDocument {
        PageDocument(content: try #require(try mac.store.pageContent(pageId)))
    }

    /// Таблица 3 × 2 с текстом в каждой ячейке, доставленная на оба Mac.
    private func sharedTable() throws -> (page: UUID, table: UUID) {
        let shared = try sharedPage(on: a, others: [b], numbering: numbering)
        var tableId: UUID!
        try edit(a, shared.page) { document in
            let anchor = try #require(document.block(shared.block))
            let table = Block(pageId: shared.page, kind: .table, sortKey: .between(anchor.sortKey, nil), props: .defaults(for: .table))
            document.apply(BlockChanges(upserts: [table] + TableGrid.contents(ofNewTable: table, columns: 3, rows: 2)))
            for row in 0..<2 {
                for column in 0..<3 {
                    document.apply(try #require(document.tableGrid(table.id)).settingText(InlineText("\(row)\(column)"), row: row, column: column))
                }
            }
            tableId = table.id
        }
        try exchange([a, b], numbering: numbering)
        return (shared.page, tableId)
    }

    private func texts(_ mac: SyncTestMac, _ page: UUID, _ table: UUID) throws -> [[String]] {
        let grid = try #require(try document(mac, page).tableGrid(table))
        return (0..<grid.rowCount).map { row in (0..<grid.columnCount).map { grid.text(row: row, column: $0).string } }
    }

    @Test("Правки разных ячеек на двух Mac сходятся без конфликта")
    func differentCellsMerge() throws {
        let shared = try sharedTable()
        a.wall.set(30_000)
        try edit(a, shared.page) { document in
            document.apply(try #require(document.tableGrid(shared.table)).settingText(InlineText("A"), row: 0, column: 0))
        }
        b.wall.set(30_500)
        try edit(b, shared.page) { document in
            document.apply(try #require(document.tableGrid(shared.table)).settingText(InlineText("B"), row: 1, column: 2))
        }
        try exchange([a, b], numbering: numbering)
        for mac in [a, b] {
            #expect(try texts(mac, shared.page, shared.table) == [["A", "01", "02"], ["10", "11", "B"]], "\(mac.name)")
            #expect(try mac.conflicts().isEmpty, "\(mac.name)")
        }
    }

    @Test("Одна ячейка на двух Mac — «Две версии», как текст блока")
    func sameCellConflicts() throws {
        let shared = try sharedTable()
        a.wall.set(30_000)
        try edit(a, shared.page) { document in
            document.apply(try #require(document.tableGrid(shared.table)).settingText(InlineText("версия A"), row: 1, column: 1))
        }
        b.wall.set(30_500)
        try edit(b, shared.page) { document in
            document.apply(try #require(document.tableGrid(shared.table)).settingText(InlineText("версия B"), row: 1, column: 1))
        }
        try exchange([a, b], numbering: numbering)
        let cell = try #require(try document(a, shared.page).tableGrid(shared.table)?.cell(row: 1, column: 1))
        for mac in [a, b] {
            let conflicts = try mac.conflicts()
            #expect(conflicts.count == 1, "\(mac.name)")
            #expect(conflicts.first?.blockId == cell.id)
            let versions = Set(conflicts.flatMap { [$0.localVersion.string, $0.remoteVersion.string] })
            #expect(versions == ["версия A", "версия B"], "\(mac.name)")
        }
    }

    @Test("Строка, добавленная на A, и столбец, добавленный на B, — оба на месте; ячейки не теряются")
    func rowAndColumnFromDifferentMacs() throws {
        let shared = try sharedTable()
        a.wall.set(30_000)
        try edit(a, shared.page) { document in
            document.apply(try #require(document.tableGrid(shared.table)).insertingRow(at: 2))
            document.apply(try #require(document.tableGrid(shared.table)).settingText(InlineText("новая строка"), row: 2, column: 0))
        }
        b.wall.set(30_500)
        try edit(b, shared.page) { document in
            document.apply(try #require(document.tableGrid(shared.table)).insertingColumn(at: 3))
            document.apply(try #require(document.tableGrid(shared.table)).settingText(InlineText("новый столбец"), row: 0, column: 3))
        }
        try exchange([a, b], numbering: numbering)
        let expected = [["00", "01", "02", "новый столбец"], ["10", "11", "12", ""], ["новая строка", "", "", ""]]
        for mac in [a, b] {
            #expect(try texts(mac, shared.page, shared.table) == expected, "\(mac.name)")
        }
    }

    @Test("Перенос блока между колонками уходит одной меткой placement и сходится")
    func moveBetweenColumnsIsOnePlacement() throws {
        let shared = try sharedPage(on: a, others: [b], numbering: numbering, text: "левый")
        var moved: UUID!
        try edit(a, shared.page) { document in
            let anchor = try #require(document.block(shared.block))
            let right = Block(pageId: shared.page, text: InlineText("правый"), sortKey: .between(anchor.sortKey, nil))
            let third = Block(pageId: shared.page, text: InlineText("третий"), sortKey: .between(right.sortKey, nil))
            document.apply(BlockChanges(upserts: [right, third]))
            document.apply(try #require(document.changesPlacing([right.id], besideRightOf: shared.block)))
            document.apply(try #require(document.changesPlacing([third.id], besideRightOf: right.id)))
            moved = third.id
        }
        try exchange([a, b], numbering: numbering)

        a.wall.set(40_000)
        try edit(a, shared.page) { document in
            let list = try #require(document.blocks.first { $0.kind == .columnList })
            let left = document.flow(list.id)[0]
            document.apply(document.changesMoving([moved], to: left.id, after: shared.block, before: nil))
        }
        let batches = try a.takeOutgoing()
        let outgoing = batches.flatMap(\.changes).filter { $0.id == moved }
        #expect(outgoing.count == 1, "у перенесённого блока меняется только место")
        if case .blockPlacement? = outgoing.first?.value {} else { Issue.record("ожидалась одна правка placement: \(outgoing)") }
        try b.receive(batches, numbering: numbering)
        try exchange([a, b], numbering: numbering)
        for mac in [a, b] {
            let document = try document(mac, shared.page)
            let list = try #require(document.blocks.first { $0.kind == .columnList }, "\(mac.name)")
            let columns = document.flow(list.id)
            #expect(columns.map { document.flow($0.id).map(\.text.string) } == [["левый", "третий"], ["правый"]], "\(mac.name)")
        }
    }

    @Test("Колонку удалили на A, а на B в неё добавили блок — блок виден за колонками, затем колонка возвращается")
    func blockOfRemovedColumnStaysVisible() throws {
        let shared = try sharedPage(on: a, others: [b], numbering: numbering, text: "левый")
        var listId: UUID!
        var rightColumn: UUID!
        try edit(a, shared.page) { document in
            let anchor = try #require(document.block(shared.block))
            let right = Block(pageId: shared.page, text: InlineText("правый"), sortKey: .between(anchor.sortKey, nil))
            document.apply(BlockChanges(upserts: [right]))
            document.apply(try #require(document.changesPlacing([right.id], besideRightOf: shared.block)))
            listId = try #require(document.blocks.first { $0.kind == .columnList }).id
            rightColumn = document.flow(listId)[1].id
        }
        try exchange([a, b], numbering: numbering)

        // На A удалили всю правую колонку, на B (не зная) добавили в неё блок.
        a.wall.set(30_000)
        try edit(a, shared.page) { document in document.apply(BlockChanges(removals: [rightColumn])) }
        b.wall.set(30_500)
        try edit(b, shared.page) { document in
            let last = document.flow(rightColumn).last
            document.replaceBlocks(in: rightColumn, after: last?.id, before: nil, with: [BlockDraft(id: nil, text: InlineText("добавлено на B"))])
        }
        // Удаление дошло до B раньше его блока: колонки нет, блок виден сразу за колонками, его запись не меняется.
        try b.receive(try a.takeOutgoing(), numbering: numbering)
        let onB = try document(b, shared.page)
        let orphan = try #require(onB.blocks.first { $0.text.string == "добавлено на B" })
        #expect(onB.isOrphan(orphan.id) && orphan.containerId == rightColumn)
        let listIndex = try #require(onB.index(ofBlock: listId))
        #expect(onB.blocks.dropFirst(listIndex + 1).contains { $0.id == orphan.id })
        try exchange([a, b], numbering: numbering)
        for mac in [a, b] {
            let document = try document(mac, shared.page)
            let texts = document.allBlocksInOrder.map(\.text.string)
            #expect(texts.contains("добавлено на B"), "\(mac.name): блок не потерян")
            #expect(document.flow(listId).count == 2, "\(mac.name): колонка вернулась, блок в ней")
        }
    }
}

extension PageDocument {
    /// Блоки всех потоков по порядку показа.
    var allBlocksInOrder: [Block] {
        func walk(_ blocks: [Block]) -> [Block] { blocks.flatMap { [$0] + walk(flow($0.id)) } }
        return walk(blocks)
    }
}
