import Foundation
import MarkdownExport
import NotesCore
import Testing
@testable import NotionImport

/// Импорт таблиц и колонок (contracts/markdown-and-notion.md): таблица Markdown Notion — таблица, первая строка —
/// строка заголовков; наша выгрузка таблиц и колонок возвращается без потерь.
@Suite("Таблицы и колонки из Markdown")
struct TablesImportTests {
    private let parser = NotionMarkdownParser()

    private func parse(_ markdown: String) -> ParsedNotionPage {
        parser.parse("# Страница\n\n" + markdown)
    }

    /// Ячейки таблицы текстом по строкам, по столбцам.
    private func cells(_ table: ParsedBlock) -> [[String]] {
        let columns = table.contained.filter { $0.kind == .tableColumn }
        let rows = table.contained.filter { $0.kind == .tableRow }
        return rows.map { row in
            columns.map { column in row.contained.first { $0.props.columnId == column.id }?.text.string ?? "" }
        }
    }

    @Test("Notion: таблица Markdown — блок-таблица, первая строка — строка заголовков, без «упрощено»")
    func notionTable() throws {
        let page = parse("| Имя | Роль |\n| --- | :-: |\n| Юрий | **автор** |\n| Мишка |  |\n| a \\| b | две<br>строки |\n\nПосле\n")
        #expect(page.blocks.map(\.kind) == [.table, .paragraph])
        let table = page.blocks[0]
        #expect(table.props.hasHeaderRow == true && table.props.hasHeaderColumn == false)
        #expect(cells(table) == [["Имя", "Роль"], ["Юрий", "автор"], ["Мишка", ""], ["a | b", "две\nстроки"]])
        let bold = try #require(table.contained.first { $0.kind == .tableRow && $0.contained.contains { $0.text.string == "автор" } })
        #expect(bold.contained.first { $0.text.string == "автор" }?.text.runs.map(\.style) == [.bold])
        #expect(page.simplifications.isEmpty)
    }

    @Test("Разбор: без пометки ширин у столбцов ширины нет (её поставит место, куда таблица встаёт); с пометкой — заданная")
    func widthsOnlyFromComment() {
        let plain = parse("| a | b |\n| --- | --- |\n")
        #expect(plain.blocks[0].contained.filter { $0.kind == .tableColumn }.map(\.props.width) == [nil, nil])
        let marked = parse("<!-- mynotion:table widths=\"120,300\" -->\n| a | b |\n| --- | --- |\n")
        #expect(marked.blocks[0].contained.filter { $0.kind == .tableColumn }.map(\.props.width) == [120, 300])
    }

    @Test("Короткая строка таблицы — недостающие ячейки пустые, без блока")
    func shortRow() {
        let page = parse("| a | b | c |\n|---|---|---|\n| 1 |\n")
        #expect(cells(page.blocks[0]) == [["a", "b", "c"], ["1", "", ""]])
        let rows = page.blocks[0].contained.filter { $0.kind == .tableRow }
        #expect(rows[1].contained.count == 1)
    }

    @Test("Круг: таблица и колонки MyNotion → Markdown → те же блоки, заголовки, ширины и доли")
    func roundTrip() throws {
        let pageId = UUID()
        var props = BlockProps.defaults(for: .table)
        props.hasHeaderRow = false
        props.hasHeaderColumn = true
        let table = Block(pageId: pageId, kind: .table, sortKey: .between(nil, nil), props: props)
        let tableContents = TableGrid.contents(ofTable: table, cells: [[InlineText("a|b"), InlineText("x\ny")], [InlineText(""), InlineText("z")]],
                                               widths: [90, 200])
        let list = Block(pageId: pageId, kind: .columnList, sortKey: .between(table.sortKey, nil))
        var left = Block(pageId: pageId, kind: .column, sortKey: .between(nil, nil), containerId: list.id)
        left.props.widthRatio = 0.25
        var right = Block(pageId: pageId, kind: .column, sortKey: .between(left.sortKey, nil), containerId: list.id)
        right.props.widthRatio = 0.75
        let inLeft = Block(pageId: pageId, kind: .heading2, text: InlineText("Слева"), sortKey: .between(nil, nil), containerId: left.id)
        let inRight = Block(pageId: pageId, kind: .checkbox, text: InlineText("Справа"), isChecked: true, sortKey: .between(nil, nil),
                            containerId: right.id)
        let markdown = MarkdownBlockWriter().markdown(for: [table, list, left, right, inLeft, inRight] + tableContents, resolveLink: { _ in nil })
        let parsed = parser.parse("# Страница\n\n" + markdown)
        #expect(parsed.blocks.map(\.kind) == [.table, .columnList])
        #expect(parsed.simplifications.isEmpty)

        let parsedTable = parsed.blocks[0]
        #expect(parsedTable.props.hasHeaderRow == false && parsedTable.props.hasHeaderColumn == true)
        #expect(parsedTable.contained.filter { $0.kind == .tableColumn }.map(\.props.width) == [90, 200])
        #expect(cells(parsedTable) == [["a|b", "x\ny"], ["", "z"]])

        let columns = parsed.blocks[1].contained
        #expect(columns.map(\.kind) == [.column, .column])
        #expect(columns.map(\.props.widthRatio) == [0.25, 0.75])
        #expect(columns[0].contained.map(\.kind) == [.heading2] && columns[0].contained[0].text.string == "Слева")
        #expect(columns[1].contained.map(\.kind) == [.checkbox] && columns[1].contained[0].isChecked)
    }

    @Test("Импорт кладёт таблицу и колонки в базу: ячейки — в строках, у ячейки — id её столбца")
    @MainActor
    func importerWritesContainers() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TablesImport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "# Таблица\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n\n<div data-columns>\n<div data-column>\n\nлево\n\n</div>\n<div data-column>\n\nправо\n\n</div>\n</div>\n"
            .write(to: folder.appendingPathComponent("Таблица 0123456789abcdef0123456789abcdef.md"), atomically: true, encoding: .utf8)
        let database = FileManager.default.temporaryDirectory.appendingPathComponent("TablesImport-\(UUID().uuidString).sqlite")
        let store = try NotesStore(database: AppDatabase.open(at: database), clock: HybridLogicalClock(deviceId: UUID()))
        let prepared = try NotionExportUnpacker().prepare(folder)
        defer { prepared.discard() }
        _ = try NotionImporter(store: store).importExport(prepared)
        let page = try #require(try store.pageOutline().first { $0.title == "Таблица" })
        let document = PageDocument(content: try #require(try store.pageContent(page.id)))
        #expect(document.blocks.map(\.kind) == [.table, .columnList])
        let grid = try #require(document.tableGrid(document.blocks[0].id))
        #expect((0..<2).map { row in (0..<2).map { grid.text(row: row, column: $0).string } } == [["A", "B"], ["1", "2"]])
        #expect(grid.hasHeaderRow)
        #expect((0..<2).map { grid.width(ofColumn: $0) } == [358, 358], "таблица без ширин — на всю колонку текста поровну")
        let columns = document.flow(document.blocks[1].id)
        #expect(columns.map { document.flow($0.id).map(\.text.string) } == [["лево"], ["право"]])
    }
}
