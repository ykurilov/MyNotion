import AppKit
import Testing
@testable import NotesCore
@testable import PageEditor
import VisualStyle

/// Простая таблица в редакторе (contracts/blocks-and-keys.md, «Таблица»; research R3): ячейки рисует вид таблицы,
/// правит одно поле на ячейку — тот же редактор, что текст страницы, с одним блоком ячейки.
@MainActor
@Suite("Таблица в редакторе")
struct TableEditingTests {
    /// Абзац «до», таблица из «/» → «Таблица», абзац «после».
    func tableFixture() throws -> (editor: EditorFixture, table: UUID) {
        let editor = try EditorFixture([.paragraph("до"), .paragraph(), .paragraph("после")])
        editor.placeCaret(inBlock: 1)
        editor.type("/табл")
        // По «табл» находятся и базы (004, contracts/database-ui.md): простая таблица — первой.
        #expect(editor.textView.popups.visibleItems.map(\.action).first == .insertTable)
        editor.press(#selector(NSResponder.insertNewline(_:)))
        let table = try #require(editor.document.blocks.first { $0.kind == .table }).id
        editor.layoutViewport()
        return (editor, table)
    }

    func grid(_ editor: EditorFixture, _ table: UUID) throws -> TableGrid {
        try #require(editor.document.tableGrid(table))
    }

    func texts(_ editor: EditorFixture, _ table: UUID) throws -> [[String]] {
        let grid = try grid(editor, table)
        return (0..<grid.rowCount).map { row in (0..<grid.columnCount).map { grid.text(row: row, column: $0).string } }
    }

    func view(_ editor: EditorFixture, _ table: UUID) throws -> TableView {
        try #require(editor.textView.tableView(for: table))
    }

    /// Поле правки ячейки, в котором сейчас фокус.
    func cellEditor(_ editor: EditorFixture) throws -> TableCellEditor {
        try #require(editor.window.firstResponder as? TableCellEditor)
    }

    func type(_ text: String, in editor: EditorFixture) throws {
        for character in text {
            let cell = try cellEditor(editor)
            editor.step { cell.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0)) }
        }
    }

    func press(_ selector: Selector, in editor: EditorFixture) throws {
        let cell = try cellEditor(editor)
        editor.step { cell.doCommand(by: selector) }
    }

    // MARK: Вставка и набор

    @Test("«/» → «Таблица» — 2 столбца × 3 строки во всю ширину (240 и остаток), курсор в первой ячейке; таблица — один знак-вложение")
    func slashTable() throws {
        let (editor, table) = try tableFixture()
        let grid = try grid(editor, table)
        #expect(grid.columnCount == 2 && grid.rowCount == 3)
        // Как у Notion 7.39: первый столбец 240, второй — до края колонки текста.
        let available = Double(Metrics.Page.columnWidth - 2 * Metrics.Page.blockHorizontalPadding)
        #expect(grid.columns.map(\.props.width) == [240, available - 240])
        #expect(editor.textView.string == "до\n\u{FFFC}\nпосле\n")
        let cell = try cellEditor(editor)
        #expect(try view(editor, table).activeCell == TableCellPosition(row: 0, column: 0))
        #expect(cell.string == "\n")
        editor.undo()
        #expect(editor.document.blocks.allSatisfy { $0.kind != .table })
    }

    @Test("Набор в ячейке создаёт её блок; ⇧Enter — перенос внутри ячейки; ⌘Z — по шагу")
    func typingInCell() throws {
        let (editor, table) = try tableFixture()
        try type("ab", in: editor)
        try press(#selector(NSResponder.insertLineBreak(_:)), in: editor)
        try type("c", in: editor)
        #expect(try texts(editor, table)[0] == ["ab\nc", ""])
        #expect(try grid(editor, table).cell(row: 0, column: 0) != nil)
        editor.undo()
        #expect(try texts(editor, table)[0][0] == "ab\n")
        _ = try editor.savedBlocks()
        let reopened = try EditorFixture(reopening: editor)
        #expect(try texts(reopened, table)[0][0] == "ab\n")
    }

    @Test("Tab / ⇧Tab — следующая и предыдущая ячейка; Tab в последней — новая строка")
    func tabNavigation() throws {
        let (editor, table) = try tableFixture()
        let tableView = try view(editor, table)
        try press(#selector(NSResponder.insertTab(_:)), in: editor)
        #expect(tableView.activeCell == TableCellPosition(row: 0, column: 1))
        try press(#selector(NSResponder.insertBacktab(_:)), in: editor)
        #expect(tableView.activeCell == TableCellPosition(row: 0, column: 0))
        for _ in 0..<5 { try press(#selector(NSResponder.insertTab(_:)), in: editor) }
        #expect(tableView.activeCell == TableCellPosition(row: 2, column: 1))
        try press(#selector(NSResponder.insertTab(_:)), in: editor)
        #expect(try grid(editor, table).rowCount == 4)
        #expect(tableView.activeCell == TableCellPosition(row: 3, column: 0))
        editor.undo()
        #expect(try grid(editor, table).rowCount == 3)
    }

    @Test("Стрелки на краю текста ячейки — в соседнюю ячейку; Enter — та же колонка строкой ниже")
    func arrowsAndEnter() throws {
        let (editor, table) = try tableFixture()
        let tableView = try view(editor, table)
        try type("ab", in: editor)
        try press(#selector(NSResponder.moveLeft(_:)), in: editor)
        #expect(tableView.activeCell == TableCellPosition(row: 0, column: 0), "внутри текста — по тексту")
        try press(#selector(NSResponder.moveRight(_:)), in: editor)
        try press(#selector(NSResponder.moveRight(_:)), in: editor)
        #expect(tableView.activeCell == TableCellPosition(row: 0, column: 1))
        #expect(try cellEditor(editor).selectedRange().location == 0)
        try press(#selector(NSResponder.moveLeft(_:)), in: editor)
        #expect(tableView.activeCell == TableCellPosition(row: 0, column: 0))
        #expect(try cellEditor(editor).selectedRange().location == 2, "в конец текста соседней ячейки")
        try press(#selector(NSResponder.moveDown(_:)), in: editor)
        #expect(tableView.activeCell == TableCellPosition(row: 1, column: 0))
        try press(#selector(NSResponder.moveUp(_:)), in: editor)
        #expect(tableView.activeCell == TableCellPosition(row: 0, column: 0))
        try press(#selector(NSResponder.insertNewline(_:)), in: editor)
        #expect(tableView.activeCell == TableCellPosition(row: 1, column: 0))
        try press(#selector(NSResponder.moveUp(_:)), in: editor)
        try press(#selector(NSResponder.moveUp(_:)), in: editor)
        #expect(editor.window.firstResponder === editor.textView, "↑ из первой строки — в блок над таблицей")
    }

    @Test("Esc, как у Notion: ячейка выделена → её строка → таблица выделена как блок")
    func escape() throws {
        let (editor, table) = try tableFixture()
        let tableView = try view(editor, table)
        try press(#selector(NSResponder.cancelOperation(_:)), in: editor)
        #expect(tableView.selectedCells == TableCellRange(TableCellPosition(row: 0, column: 0)))
        #expect(editor.window.firstResponder === tableView)
        editor.step { tableView.doCommand(by: #selector(NSResponder.cancelOperation(_:))) }
        #expect(tableView.selectedCells == TableCellRange(from: TableCellPosition(row: 0, column: 0), to: TableCellPosition(row: 0, column: 1)))
        #expect(editor.window.firstResponder === tableView)
        editor.step { tableView.doCommand(by: #selector(NSResponder.cancelOperation(_:))) }
        #expect(editor.window.firstResponder === editor.textView)
        #expect(editor.textView.isBlockSelection && editor.textView.selectedBlockRange() == 1..<2)
    }

    // MARK: Строки и столбцы

    @Test("«+» под таблицей — строка, справа — столбец; вставка выше, ниже, слева, справа; удаление; ⌘Z каждого шага")
    func rowsAndColumns() throws {
        let (editor, table) = try tableFixture()
        let tableView = try view(editor, table)
        try type("x", in: editor)
        editor.step { tableView.addRow() }
        #expect(try grid(editor, table).rowCount == 4)
        editor.step { tableView.addColumn() }
        #expect(try grid(editor, table).columnCount == 3)
        editor.step { tableView.perform(.insertRowAbove, at: TableCellPosition(row: 0, column: 0)) }
        #expect(try texts(editor, table).map { $0[0] } == ["", "x", "", "", ""])
        editor.step { tableView.perform(.insertColumnLeft, at: TableCellPosition(row: 1, column: 0)) }
        #expect(try texts(editor, table)[1] == ["", "x", "", ""])
        editor.step { tableView.perform(.insertRowBelow, at: TableCellPosition(row: 1, column: 1)) }
        editor.step { tableView.perform(.insertColumnRight, at: TableCellPosition(row: 1, column: 1)) }
        #expect(try texts(editor, table)[1] == ["", "x", "", "", ""])
        #expect(try grid(editor, table).rowCount == 6)
        editor.step { tableView.perform(.deleteRow, at: TableCellPosition(row: 1, column: 1)) }
        editor.step { tableView.perform(.deleteColumn, at: TableCellPosition(row: 0, column: 1)) }
        #expect(try grid(editor, table).rowCount == 5 && grid(editor, table).columnCount == 4)
        #expect(try !texts(editor, table).joined().contains("x"))
        for _ in 0..<8 { editor.undo() }
        #expect(try grid(editor, table).rowCount == 3 && grid(editor, table).columnCount == 2)
        #expect(try texts(editor, table)[0][0] == "x")
    }

    @Test("Строка и столбец заголовков — свойства таблицы; ширина столбца — протяжкой границы")
    func headersAndWidth() throws {
        let (editor, table) = try tableFixture()
        let tableView = try view(editor, table)
        editor.step { tableView.perform(.toggleHeaderRow, at: TableCellPosition(row: 0, column: 0)) }
        editor.step { tableView.perform(.toggleHeaderColumn, at: TableCellPosition(row: 0, column: 0)) }
        #expect(try grid(editor, table).hasHeaderRow && grid(editor, table).hasHeaderColumn)
        let widths = try grid(editor, table).columns.map(\.props.width)
        editor.step { tableView.dragColumnBoundary(1, toWidth: 260) }
        #expect(try grid(editor, table).columns.map(\.props.width) == [widths[0], 260])
        editor.undo()
        #expect(try grid(editor, table).columns.map(\.props.width) == widths)
        editor.undo()
        #expect(try !grid(editor, table).hasHeaderColumn)
    }

    // MARK: Буфер обмена и оформление

    @Test("⌘C выделенных ячеек — текст с табуляциями и переводами строк; ⌘V такого текста — в ячейки от текущей")
    func copyAndPasteCells() throws {
        let (editor, table) = try tableFixture()
        try type("a", in: editor)
        try press(#selector(NSResponder.insertTab(_:)), in: editor)
        try type("b", in: editor)
        let tableView = try view(editor, table)
        tableView.selectCells(TableCellRange(from: TableCellPosition(row: 0, column: 0), to: TableCellPosition(row: 1, column: 1)))
        let board = NSPasteboard(name: NSPasteboard.Name("MyNotion.tests.\(UUID().uuidString)"))
        #expect(tableView.copyCells(to: board))
        #expect(board.string(forType: .string) == "a\tb\n\t")

        board.clearContents()
        board.setString("1\t2\t3\t4\n5\t6", forType: .string)
        editor.step { tableView.activate(TableCellPosition(row: 1, column: 1)) }
        editor.step { _ = try? cellEditor(editor).pasteCells(from: board) }
        // Таблица растёт под вставленное: столбцов и строк добавляется сколько нужно.
        #expect(try texts(editor, table) == [["a", "b", "", "", ""], ["", "1", "2", "3", "4"], ["", "5", "6", "", ""]])
        editor.undo()
        #expect(try texts(editor, table) == [["a", "b"], ["", ""], ["", ""]])
    }

    @Test("Оформление в ячейке: ⌘B по выделению — жирный в тексте ячейки")
    func inlineFormattingInCell() throws {
        let (editor, table) = try tableFixture()
        try type("жирно", in: editor)
        let cell = try cellEditor(editor)
        cell.setSelectedRange(NSRange(location: 0, length: 5))
        editor.step { cell.perform(.toggleInline(.bold)) }
        #expect(try grid(editor, table).text(row: 0, column: 0).runs.map(\.style) == [.bold])
        editor.undo()
        #expect(try grid(editor, table).text(row: 0, column: 0).runs.isEmpty)
    }

    @Test("В ячейке нет меню «/», быстрых символов и вложенности")
    func noBlockStructureInCell() throws {
        let (editor, table) = try tableFixture()
        try type("/", in: editor)
        #expect(try !cellEditor(editor).popups.isOpen)
        try type("- x", in: editor)
        #expect(try texts(editor, table)[0][0] == "/- x")
        #expect(try grid(editor, table).cell(row: 0, column: 0)?.kind == .tableCell)
    }
}
