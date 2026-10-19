import Foundation
import Testing
@testable import NotesCore

/// Модель таблицы (data-model.md, «Правила»; research R3): таблица — блок `table`, его столбцы `tableColumn` и строки
/// `tableRow`, у строки — ячейки `tableCell` с id своего столбца.
@MainActor
@Suite("Модель таблицы")
struct TableModelTests {
    let folder: TemporaryFolder
    let store: NotesStore
    let pageId: UUID
    let tableId: UUID

    /// Абзац, таблица 3 × 2 без ячеек, абзац.
    init() throws {
        folder = try TemporaryFolder()
        store = try NotesStore(database: AppDatabase.open(at: folder.databaseURL), clock: HybridLogicalClock(deviceId: UUID()))
        (pageId, tableId) = try store.write { tx in
            let page = try tx.createPage(title: "Таблица")
            let first = try tx.blocks(ofPage: page.id)[0]
            let table = try tx.insertBlock(Block(pageId: page.id, kind: .table, sortKey: .between(first.sortKey, nil),
                                                 props: .defaults(for: .table)))
            try tx.insertBlock(Block(pageId: page.id, text: InlineText("После"), sortKey: .between(table.sortKey, nil)))
            for block in TableGrid.contents(ofNewTable: table, columns: 3, rows: 2) { try tx.insertBlock(block) }
            return (page.id, table.id)
        }
    }

    func openDocument() throws -> PageDocument {
        PageDocument(content: try #require(try store.pageContent(pageId)))
    }

    func save(_ document: PageDocument) {
        let autosave = AutosaveCoordinator(document: document, store: store, scheduler: ManualAutosaveScheduler())
        #expect(autosave.saveNow())
        autosave.stop()
    }

    @Test("Новая таблица во всю ширину, как у Notion 7.39: первый столбец 240, второй — остаток; узко — пополам, не уже наименьшего")
    func newTableWidths() {
        #expect(TableGrid.columnWidths(ofNewTableFitting: 716) == [240, 476])
        #expect(TableGrid.columnWidths(ofNewTableFitting: 300) == [150, 150])
        #expect(TableGrid.columnWidths(ofNewTableFitting: 40) == [TableGrid.minimumColumnWidth, TableGrid.minimumColumnWidth])
    }

    @Test("Таблица — table + tableColumn + tableRow + tableCell: столбцы и строки в потоке таблицы, ячейки — в потоке строки")
    func structure() throws {
        let document = try openDocument()
        let grid = try #require(document.tableGrid(tableId))
        #expect(grid.columnCount == 3 && grid.rowCount == 2)
        #expect(grid.columns.allSatisfy { $0.kind == .tableColumn && $0.containerId == tableId && $0.props.width == 120 })
        #expect(grid.rows.allSatisfy { $0.kind == .tableRow && $0.containerId == tableId })
        #expect(document.blocks.map(\.kind) == [.paragraph, .table, .paragraph], "строки и столбцы — не в потоке страницы")
        #expect(!grid.hasHeaderRow && !grid.hasHeaderColumn)
    }

    @Test("Отсутствующая ячейка — пустая, создаётся при первом вводе; второй ввод правит ту же ячейку")
    func missingCellIsCreatedOnFirstInput() throws {
        let document = try openDocument()
        var grid = try #require(document.tableGrid(tableId))
        #expect(grid.cell(row: 1, column: 2) == nil)
        #expect(grid.text(row: 1, column: 2) == .empty)

        document.apply(grid.settingText(InlineText("Б3"), row: 1, column: 2))
        grid = try #require(document.tableGrid(tableId))
        let cell = try #require(grid.cell(row: 1, column: 2))
        #expect(cell.kind == .tableCell)
        #expect(cell.containerId == grid.rows[1].id)
        #expect(cell.props.columnId == grid.columns[2].id)
        #expect(grid.text(row: 1, column: 2).string == "Б3")

        document.apply(grid.settingText(InlineText("Б3!"), row: 1, column: 2))
        grid = try #require(document.tableGrid(tableId))
        #expect(grid.cell(row: 1, column: 2)?.id == cell.id)
        #expect(document.flow(grid.rows[1].id).count == 1)

        save(document)
        let reopened = try #require(try openDocument().tableGrid(tableId))
        #expect(reopened.text(row: 1, column: 2).string == "Б3!")
        #expect(reopened.text(row: 0, column: 0) == .empty)
    }

    @Test("Ячейка удалённого или неизвестного столбца не показывается")
    func cellOfRemovedColumnIsHidden() throws {
        let document = try openDocument()
        var grid = try #require(document.tableGrid(tableId))
        document.apply(grid.settingText(InlineText("в третьем"), row: 0, column: 2))
        grid = try #require(document.tableGrid(tableId))
        let stray = Block(pageId: pageId, kind: .tableCell, text: InlineText("чужая"), sortKey: .between(nil, nil),
                          containerId: grid.rows[0].id, props: { var props = BlockProps(); props.columnId = UUID(); return props }())
        document.apply(BlockChanges(upserts: [stray]))
        grid = try #require(document.tableGrid(tableId))
        #expect((0..<3).map { grid.text(row: 0, column: $0).string } == ["", "", "в третьем"])

        document.apply(grid.removingColumn(at: 2))
        grid = try #require(document.tableGrid(tableId))
        #expect(grid.columnCount == 2)
        #expect((0..<2).map { grid.text(row: 0, column: $0).string } == ["", ""])
    }

    @Test("Вставка строки и столбца в любое место; порядок — по ключам")
    func insertRowsAndColumns() throws {
        let document = try openDocument()
        var grid = try #require(document.tableGrid(tableId))
        for row in 0..<2 {
            for column in 0..<3 {
                document.apply(grid.settingText(InlineText("\(row)\(column)"), row: row, column: column))
                grid = try #require(document.tableGrid(tableId))
            }
        }
        document.apply(grid.insertingRow(at: 1))
        grid = try #require(document.tableGrid(tableId))
        document.apply(grid.insertingColumn(at: 0))
        grid = try #require(document.tableGrid(tableId))
        #expect(grid.rowCount == 3 && grid.columnCount == 4)
        let texts = (0..<3).map { row in (0..<4).map { grid.text(row: row, column: $0).string } }
        #expect(texts == [["", "00", "01", "02"], ["", "", "", ""], ["", "10", "11", "12"]])
        #expect(grid.columns[0].props.width == 120)

        save(document)
        let reopened = try #require(try openDocument().tableGrid(tableId))
        #expect((0..<3).map { row in (0..<4).map { reopened.text(row: row, column: $0).string } } == texts)
    }

    @Test("Удаление строки уносит её ячейки; удаление последней строки или столбца удаляет таблицу")
    func removingLastRowRemovesTable() throws {
        let document = try openDocument()
        var grid = try #require(document.tableGrid(tableId))
        document.apply(grid.settingText(InlineText("x"), row: 0, column: 0))
        grid = try #require(document.tableGrid(tableId))
        let cell = try #require(grid.cell(row: 0, column: 0))
        document.apply(grid.removingRow(at: 0))
        #expect(document.block(cell.id) == nil)
        grid = try #require(document.tableGrid(tableId))
        #expect(grid.rowCount == 1)
        document.apply(grid.removingRow(at: 0))
        #expect(document.tableGrid(tableId) == nil)
        #expect(document.blocks.map(\.kind) == [.paragraph, .paragraph])

        let other = try openDocument()
        var otherGrid = try #require(other.tableGrid(tableId))
        other.apply(otherGrid.removingColumn(at: 0))
        other.apply(try #require(other.tableGrid(tableId)).removingColumn(at: 0))
        otherGrid = try #require(other.tableGrid(tableId))
        #expect(otherGrid.columnCount == 1)
        other.apply(otherGrid.removingColumn(at: 0))
        #expect(other.tableGrid(tableId) == nil)
        save(other)
        #expect(try #require(try store.pageContent(pageId)).blocks.map(\.kind) == [.paragraph, .paragraph])
    }

    @Test("Строка и столбец заголовков, ширина столбца — свойства, переживают запись")
    func headersAndWidth() throws {
        let document = try openDocument()
        var grid = try #require(document.tableGrid(tableId))
        document.apply(grid.settingHeaders(row: true, column: false))
        grid = try #require(document.tableGrid(tableId))
        document.apply(grid.settingWidth(200, ofColumn: 1))
        save(document)
        let reopened = try #require(try openDocument().tableGrid(tableId))
        #expect(reopened.hasHeaderRow && !reopened.hasHeaderColumn)
        #expect(reopened.columns.map(\.props.width) == [120, 200, 120])
    }

    @Test("Каждая правка возвращает обратную: её применение возвращает таблицу как была, с теми же id")
    func inverseRestoresExactly() throws {
        let document = try openDocument()
        var grid = try #require(document.tableGrid(tableId))
        let before = Set(document.allBlocksForTests)
        let edits: [(TableGrid) -> BlockChanges] = [
            { $0.settingText(InlineText("a"), row: 0, column: 0) },
            { $0.insertingRow(at: 2) },
            { $0.insertingColumn(at: 1) },
            { $0.removingColumn(at: 0) },
            { $0.removingRow(at: 0) },
            { $0.settingHeaders(row: true, column: true) },
            { $0.settingWidth(90, ofColumn: 0) },
        ]
        var inverses: [BlockChanges] = []
        for edit in edits {
            inverses.append(document.apply(edit(grid)))
            grid = try #require(document.tableGrid(tableId))
        }
        for inverse in inverses.reversed() { document.apply(inverse) }
        #expect(Set(document.allBlocksForTests) == before)
        save(document)
        #expect(Set(try #require(try store.pageContent(pageId)).blocks.map(\.id)) == Set(before.map(\.id)))
    }

    @Test("Удаление таблицы и ⌘Z: строки, столбцы и ячейки возвращаются вместе с ней")
    func removedTableComesBackWithContents() throws {
        let document = try openDocument()
        let grid = try #require(document.tableGrid(tableId))
        document.apply(grid.settingText(InlineText("ячейка"), row: 1, column: 1))
        let first = document.blocks[0].id, last = document.blocks[2].id
        let table = BlockDraft(try #require(document.block(tableId)))
        document.replaceBlocks(after: first, before: last, with: [])
        #expect(document.blocks.count == 2)
        // ⌘Z удаления абзаца-таблицы возвращает её черновиком прежнего блока.
        let ids = document.replaceBlocks(after: first, before: last, with: [table])
        let restored = try #require(document.tableGrid(ids[0]))
        #expect(restored.columnCount == 3 && restored.rowCount == 2)
        #expect(restored.text(row: 1, column: 1).string == "ячейка")
        save(document)
        let reopened = try #require(try openDocument().tableGrid(ids[0]))
        #expect(reopened.text(row: 1, column: 1).string == "ячейка")
    }
}

extension PageDocument {
    /// Все блоки страницы, всех потоков.
    var allBlocksForTests: [Block] {
        func walk(_ blocks: [Block]) -> [Block] { blocks.flatMap { [$0] + walk(flow($0.id)) } }
        return walk(blocks)
    }
}
