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

    @Test("allBlocks открытой страницы включает столбцы и строки таблицы, которых нет в потоке страницы")
    func allBlocksIncludeTableContents() throws {
        let document = try openDocument()
        let stored = try #require(try store.pageContent(pageId)).blocks
        #expect(Set(document.allBlocks.map(\.id)) == Set(stored.map(\.id)))
        #expect(document.allBlocks.contains { $0.kind == .tableRow })
        #expect(!document.blocks.contains { $0.kind == .tableRow })
    }

    @Test("Новая таблица во всю ширину: столбцы делят её поровну, остаток — последнему; узко — не уже порога, дальше шире колонки")
    func newTableWidths() {
        let narrowest = TableGrid.narrowestFittedColumnWidth
        #expect(narrowest == 100)
        #expect(TableGrid.columnWidths(ofNewTable: 2, fitting: 716) == [358, 358])
        #expect(TableGrid.columnWidths(ofNewTable: 3, fitting: 716) == [238, 238, 240])
        #expect(TableGrid.columnWidths(ofNewTable: 1, fitting: 716) == [716])
        #expect(TableGrid.columnWidths(ofNewTable: 7, fitting: 716) == [102, 102, 102, 102, 102, 102, 104])
        #expect(TableGrid.columnWidths(ofNewTable: 10, fitting: 716) == Array(repeating: narrowest, count: 10))
        #expect(TableGrid.columnWidths(ofNewTable: 2, fitting: 40) == [narrowest, narrowest])
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

    @Test("Удаление столбца уносит и вторую ячейку того же столбца в строке (ввод двух Mac разом): она не вернёт столбец")
    func removingColumnTakesDuplicateCells() throws {
        let document = try openDocument()
        var grid = try #require(document.tableGrid(tableId))
        document.apply(grid.settingText(InlineText("с этого Mac"), row: 0, column: 1))
        grid = try #require(document.tableGrid(tableId))
        let columnId = grid.columns[1].id
        let first = try #require(grid.cell(row: 0, column: 1))
        let twin = Block(pageId: pageId, kind: .tableCell, text: InlineText("с другого Mac"), sortKey: .between(first.sortKey, nil),
                         containerId: grid.rows[0].id, props: { var props = BlockProps(); props.columnId = columnId; return props }())
        document.apply(BlockChanges(upserts: [twin]))
        grid = try #require(document.tableGrid(tableId))
        #expect(grid.text(row: 0, column: 1).string == "с этого Mac", "показывается первая")

        document.apply(grid.removingColumn(at: 1))

        #expect(document.flow(grid.rows[0].id).allSatisfy { $0.props.columnId != columnId })
        #expect(document.block(twin.id) == nil)
    }

    func widths(_ document: PageDocument) throws -> [Double] {
        let grid = try #require(document.tableGrid(tableId))
        return (0..<grid.columnCount).map { grid.width(ofColumn: $0) }
    }

    func setWidths(_ widths: [Double], in document: PageDocument) throws {
        for (index, width) in widths.enumerated() {
            document.apply(try #require(document.tableGrid(tableId)).settingWidth(width, ofColumn: index))
        }
    }

    @Test("Новый столбец встаёт в ширину таблицы: его доля — поровну на всех, остальные сужаются пропорционально, не уже порога")
    func newColumnFitsTableWidth() throws {
        let document = try openDocument()
        try setWidths([200, 400, 200], in: document)
        document.apply(try #require(document.tableGrid(tableId)).insertingColumn(at: 3))
        #expect(try widths(document) == [150, 300, 150, 200])

        // Узкие соседи упираются в порог (100), остаток отдают широкие.
        try setWidths([120, 400, 120], in: document)
        document.apply(try #require(document.tableGrid(tableId)).insertingColumn(at: 4))
        let shrunk = try widths(document)
        #expect(shrunk.count == 5 && shrunk.reduce(0, +) == 840, "\(shrunk)")
        #expect(shrunk[4] == 168, "\(shrunk)")
        #expect(shrunk.allSatisfy { $0 >= TableGrid.narrowestFittedColumnWidth }, "\(shrunk)")
    }

    @Test("Сужать некуда — столбцы на пороге остаются, таблица расширяется; столбцы уже порога (протянуты руками) не меняются")
    func newColumnWidensTableAtThreshold() throws {
        let document = try openDocument()
        try setWidths([100, 100, 100], in: document)
        document.apply(try #require(document.tableGrid(tableId)).insertingColumn(at: 3))
        #expect(try widths(document) == [100, 100, 100, 100])

        try setWidths([100, 300, 200, 100], in: document)
        document.apply(try #require(document.tableGrid(tableId)).insertingColumn(at: 4))
        #expect(try widths(document) == [100, 216, 144, 100, 140])

        let minimum = TableGrid.minimumColumnWidth
        try setWidths([minimum, 60, 400, 100, 100], in: document)
        document.apply(try #require(document.tableGrid(tableId)).insertingColumn(at: 0))
        let manual = try widths(document)
        #expect(manual[0] == 115 && manual[1] == minimum && manual[2] == 60, "\(manual)")
        #expect(manual.reduce(0, +) == 692, "\(manual)")
    }

    @Test("Удаление столбца ширины остальных не трогает")
    func removingColumnKeepsWidths() throws {
        let document = try openDocument()
        try setWidths([120, 400, 200], in: document)
        document.apply(try #require(document.tableGrid(tableId)).removingColumn(at: 1))
        #expect(try widths(document) == [120, 200])
    }

    @Test("Ширины всех столбцов сразу: одна правка, не уже наименьшей; число ширин не по числу столбцов — нет правки")
    func settingAllWidths() throws {
        let document = try openDocument()
        let grid = try #require(document.tableGrid(tableId))
        let changes = grid.settingWidths([200, 10, 300.4])
        #expect(changes.upserts.count == 3 && changes.removals.isEmpty)
        document.apply(changes)
        #expect(try widths(document) == [200, TableGrid.minimumColumnWidth, 300])
        #expect(try #require(document.tableGrid(tableId)).settingWidths([1, 2]).isEmpty)
        #expect(try #require(document.tableGrid(tableId)).settingWidths([200, 32, 300]).isEmpty, "те же ширины — нет правки")
    }

    @Test("Старая таблица без ширин остаётся узкой (120), пока её не правят")
    func oldTableKeepsDefaultWidth() throws {
        let document = try openDocument()
        let grid = try #require(document.tableGrid(tableId))
        var column = grid.columns[0]
        column.props.width = nil
        document.apply(BlockChanges(upserts: [column]))
        #expect(try #require(document.tableGrid(tableId)).width(ofColumn: 0) == TableGrid.defaultColumnWidth)
    }

    // MARK: Новые таблицы без окна

    /// Таблица страницы (или вложенная в `containerId`) и её столбцы с ширинами `widths`.
    func freeTable(widths: [Double?], indent: Int = 0, containerId: UUID? = nil, key: FractionalSortKey = .between(nil, nil)) -> [Block] {
        let table = Block(pageId: pageId, kind: .table, indent: indent, sortKey: key, containerId: containerId, props: .defaults(for: .table))
        var contents = TableGrid.contents(ofTable: table, cells: [widths.map { _ in InlineText("x") }])
        let columns = contents.indices.filter { contents[$0].kind == .tableColumn }
        for (position, index) in columns.enumerated() { contents[index].props.width = widths[position] }
        return [table] + contents
    }

    func columnWidths(_ blocks: [Block], of table: Block) -> [Double?] {
        blocks.filter { $0.kind == .tableColumn && $0.containerId == table.id }.sorted { $0.sortKey < $1.sortKey }.map(\.props.width)
    }

    @Test("Без окна: таблица без ширин — на стандартную колонку текста поровну; с отступом — уже; заданные ширины остаются")
    func fittingNewTablesWithoutWindow() {
        let plain = freeTable(widths: [nil, nil, nil])
        let indented = freeTable(widths: [nil, nil], indent: 1, key: .between(plain[0].sortKey, nil))
        let explicit = freeTable(widths: [120, nil], key: .between(indented[0].sortKey, nil))
        let fitted = TableGrid.fittingNewTables(in: plain + indented + explicit)
        #expect(TableGrid.standardTextWidth == 716)
        #expect(columnWidths(fitted, of: plain[0]) == [238, 238, 240])
        #expect(columnWidths(fitted, of: indented[0]) == [342, 342])
        #expect(columnWidths(fitted, of: explicit[0]) == [120, nil])
        #expect(fitted.count == plain.count + indented.count + explicit.count)
    }

    @Test("Без окна: таблица в колонке страницы — на ширину своей колонки")
    func fittingTableInColumn() {
        let list = Block(pageId: pageId, kind: .columnList, sortKey: .between(nil, nil))
        var left = Block(pageId: pageId, kind: .column, sortKey: .between(nil, nil), containerId: list.id)
        left.props.widthRatio = 0.25
        var right = Block(pageId: pageId, kind: .column, sortKey: .between(left.sortKey, nil), containerId: list.id)
        right.props.widthRatio = 0.75
        let table = freeTable(widths: [nil, nil], containerId: right.id)
        let fitted = TableGrid.fittingNewTables(in: [list, left, right] + table)
        // (716 − просвет 46) × 0,75 = 502,5 → 502.
        #expect(columnWidths(fitted, of: table[0]) == [251, 251])
    }

    @Test("Ширина под таблицей в документе — та же, что без окна в блоках")
    func standardWidthInDocument() throws {
        let document = try openDocument()
        let table = try #require(document.block(tableId))
        #expect(document.standardTableWidth(of: table) == 716)
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
        #expect(grid.columns.map(\.props.width) == [100, 100, 100, 100], "3 × 120: сузиться до порога 100 и вместить новый нельзя — таблица шире")

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
