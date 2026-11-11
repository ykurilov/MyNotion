import ControlProtocol
import Foundation
import Testing
@testable import ControlCommands
@testable import NotesCore

/// Ширины столбцов таблицы командами: новая таблица встаёт во всю колонку текста, `block table-widths` подгоняет
/// столбцы под содержимое одной правкой.
@MainActor @Suite struct TableWidthCommandsTests {
    let host: TestHost
    let executor: CommandExecutor
    let page: Page

    init() throws {
        host = try TestHost()
        executor = CommandExecutor(host: host, log: RecordingLog())
        page = try host.page("Таблицы", texts: ["один"])
    }

    @discardableResult
    func run(_ command: String, _ args: [String: ControlJSON] = [:]) async -> ControlResponse {
        await executor.run(ControlRequest(command: command, args: args))
    }

    /// Ширины столбцов первой таблицы страницы, как записаны в базе.
    func widths() throws -> [Double] {
        let content = try #require(try host.store.pageContent(page.id))
        let table = try #require(content.blocks.first { $0.kind == .table })
        let grid = TableGrid(table: table) { containerId in
            content.blocks.filter { $0.containerId == containerId }.sorted { $0.sortKey < $1.sortKey }
        }
        return (0..<grid.columnCount).map { grid.width(ofColumn: $0) }
    }

    func pageArgs(_ args: [String: ControlJSON]) -> [String: ControlJSON] {
        args.merging(["page": .string(page.id.controlText)]) { _, page in page }
    }

    func tableId() throws -> UUID {
        try #require(try host.store.pageContent(page.id)?.blocks.first { $0.kind == .table }).id
    }

    @Test func insertedTableFillsTextColumn() async throws {
        let response = await run("block.insert", pageArgs([
            "kind": "table", "props": ["rows": [["Имя", "Возраст", "Город"], ["Аня", "7", "Бали"]]], "last": true,
        ]))
        #expect(response.ok)
        #expect(try widths() == [238, 238, 240])
    }

    @Test func emptyInsertedTableFillsTextColumn() async throws {
        #expect(await run("block.insert", pageArgs(["kind": "table", "last": true])).ok)
        #expect(try widths() == [358, 358])
    }

    @Test func markdownTableFillsTextColumnUnlessWidthsGiven() async throws {
        #expect(await run("page.write", ["page": .string(page.id.controlText), "markdown": "| А | Б |\n| --- | --- |\n| 1 | 2 |"]).ok)
        #expect(try widths() == [358, 358])
        let marked = "<!-- mynotion:table widths=\"100,250\" -->\n| А | Б |\n| --- | --- |\n| 1 | 2 |"
        #expect(await run("page.write", ["page": .string(page.id.controlText), "markdown": .string(marked)]).ok)
        #expect(try widths() == [100, 250])
    }

    @Test func readAndWriteKeepOldTableWidths() async throws {
        #expect(await run("block.insert", pageArgs(["kind": "table", "last": true])).ok)
        // Старая таблица: столбцы по 120, как до заполнения ширины.
        try host.store.write { tx in
            for column in try tx.blocks(ofPage: page.id) where column.kind == .tableColumn {
                var column = column
                column.props.width = nil
                _ = try tx.updateBlock(column)
            }
        }
        let read = await run("page.read", ["page": .string(page.id.controlText)])
        let markdown = try #require(read.data?["markdown"]?.string)
        #expect(await run("page.write", ["page": .string(page.id.controlText), "markdown": .string(markdown)]).ok)
        #expect(try widths() == [120, 120])
    }

    @Test func tableWidthsSetsAllColumns() async throws {
        #expect(await run("block.insert", pageArgs(["kind": "table", "props": ["rows": [["a", "b", "c"]]], "last": true])).ok)
        let table = try tableId()
        let response = await run("block.table-widths", ["block": .string(table.controlText), "widths": ["200", "120", "396"]])
        #expect(response.ok, "\(response.error?.message ?? "")")
        #expect(try widths() == [200, 120, 396])
        // Список строкой через запятую — как из командной строки.
        #expect(await run("block.table-widths", ["block": .string(table.controlText), "widths": "150, 150,300"]).ok)
        #expect(try widths() == [150, 150, 300])
    }

    @Test func tableWidthsRejectsWrongCountAndNonTable() async throws {
        #expect(await run("block.insert", pageArgs(["kind": "table", "last": true])).ok)
        let wrongCount = await run("block.table-widths", ["block": .string(try tableId().controlText), "widths": ["100"]])
        #expect(wrongCount.error?.code == .invalidValue)
        let notNumber = await run("block.table-widths", ["block": .string(try tableId().controlText), "widths": ["широко", "100"]])
        #expect(notNumber.error?.code == .invalidValue)
        let paragraph = try #require(try host.store.pageContent(page.id)?.blocks.first { $0.kind == .paragraph })
        let notTable = await run("block.table-widths", ["block": .string(paragraph.id.controlText), "widths": ["100"]])
        #expect(notTable.error?.code == .invalidArgument)
        #expect(try widths() == [358, 358])
    }

    #if DEBUG
    @Test func tableWidthsIsOneUndoStep() async throws {
        #expect(await run("block.insert", pageArgs(["kind": "table", "props": ["rows": [["a", "b", "c"]]], "last": true])).ok)
        #expect(await run("block.table-widths", ["block": .string(try tableId().controlText), "widths": ["200", "120", "396"]]).ok)
        executor.lastUndoManager?.undo()
        #expect(try widths() == [238, 238, 240])
        executor.lastUndoManager?.redo()
        #expect(try widths() == [200, 120, 396])
    }
    #endif
}
