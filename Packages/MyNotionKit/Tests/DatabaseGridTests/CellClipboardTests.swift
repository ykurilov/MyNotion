import Foundation
import Testing
@testable import DatabaseGrid
@testable import Databases
@testable import NotesCore

/// Буфер ячеек (T032): ⌘C — табуляции и переводы строк плюс простая таблица HTML (для Numbers), ⌘V — с добавлением
/// строк и обрезкой колонок, ⌫ — стирает; вставка — один шаг отмены.
@MainActor
@Suite("Сетка: буфер ячеек")
struct CellClipboardTests {
    @Test("⌘C: TSV — ячейки через табуляцию, строки через перевод строки; ячейка с табуляцией или переводом — в кавычках")
    func copyTSV() {
        #expect(CellClipboard.tsv([["Купить", "12"], ["Продать", ""]]) == "Купить\t12\nПродать\t")
        #expect(CellClipboard.tsv([["две\nстроки", "a\tb", "«ок» \"да\""]]) == "\"две\nстроки\"\t\"a\tb\"\t\"«ок» \"\"да\"\"\"")
    }

    @Test("⌘C: HTML — таблица со строками и ячейками, текст экранирован")
    func copyHTML() {
        let html = CellClipboard.html([["A & B", "<1>"], ["в", ""]])
        #expect(html.contains("<table>") && html.contains("</table>"))
        #expect(html.components(separatedBy: "<tr>").count == 3)
        #expect(html.contains("<td>A &amp; B</td>") && html.contains("<td>&lt;1&gt;</td>") && html.contains("<td></td>"))
    }

    @Test("Разбор TSV из Numbers: кавычки, переводы строк внутри, \\r\\n, хвостовой перевод строки")
    func parse() {
        #expect(CellClipboard.parse("a\tb\r\nc\td\r\n") == [["a", "b"], ["c", "d"]])
        #expect(CellClipboard.parse("\"две\nстроки\"\t\"с \"\"кавычкой\"\"\"") == [["две\nстроки", "с \"кавычкой\""]])
        #expect(CellClipboard.parse("одно") == [["одно"]])
        #expect(CellClipboard.parse("") == [])
    }

    @MainActor
    struct Fixture {
        let store: NotesStore
        let undo = UndoManager()
        let operations: DatabaseOperations
        let base: CreatedDatabase
        let number: DatabaseProperty
        let check: DatabaseProperty
        let rows: [UUID]

        @MainActor
        init() throws {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            store = NotesStore(database: try AppDatabase.open(at: folder.appendingPathComponent("MyNotion.sqlite")), clock: HybridLogicalClock(deviceId: UUID()))
            undo.groupsByEvent = false
            operations = DatabaseOperations(store: store)
            base = try operations.createDatabase(in: nil, isInline: false, title: "Задачи")
            number = try operations.addProperty(to: base.databaseId, name: "Часы", kind: .number)
            check = try operations.addProperty(to: base.databaseId, name: "Готово", kind: .checkbox)
            let operations = operations, base = base
            rows = try (0..<2).map { try operations.addRow(to: base.databaseId, in: base.viewId, title: "Строка \($0)") }
            operations.undoManager = undo
        }

        var contexts: [PropertyContext] {
            get throws {
                let catalog = try DatabaseCatalog.read(base.databaseId, in: store)
                return catalog.properties.map { catalog.context(for: $0) }
            }
        }

        func title(_ row: UUID) throws -> String? { try store.write { try $0.page(row)?.title } }
        func value(_ row: UUID, _ property: DatabaseProperty) throws -> JSONValue? {
            try store.write { try $0.cell(rowId: row, propertyId: property.id)?.value }
        }
    }

    @Test("⌘V: блок со второй строки добавляет строки, лишние колонки отбрасываются; один шаг ⌘Z")
    func pasteAppendsRows() throws {
        let fixture = try Fixture()
        let plan = CellClipboard.pastePlan(CellClipboard.parse("Новая А\t5\tYes\tлишнее\nНовая Б\t7,5\tNo\tлишнее\nНовая В\t\tYes"),
                                           at: CellSelection(CellPosition(row: 1, column: 0)), rowIds: fixture.rows,
                                           contexts: try fixture.contexts)
        #expect(plan.appendedRows == 2)
        #expect(plan.writes.count == 9, "три строки × три колонки, четвёртая отброшена")
        fixture.undo.beginUndoGrouping()
        let appended = try fixture.operations.writeCells(plan.writes, appendingRows: plan.appendedRows, to: fixture.base.databaseId,
                                                         in: fixture.base.viewId)
        fixture.undo.endUndoGrouping()
        #expect(try fixture.title(fixture.rows[1]) == "Новая А")
        #expect(try fixture.value(fixture.rows[1], fixture.number) == .number(5))
        #expect(try fixture.value(fixture.rows[1], fixture.check) == .bool(true))
        #expect(try fixture.title(appended[0]) == "Новая Б")
        #expect(try fixture.value(appended[0], fixture.number) == .number(7.5))
        #expect(try fixture.value(appended[1], fixture.number) == nil)
        #expect(try fixture.title(fixture.rows[0]) == "Строка 0", "выше начала вставки не трогается")
        fixture.undo.undo()
        #expect(try fixture.title(fixture.rows[1]) == "Строка 1")
        #expect(try fixture.value(fixture.rows[1], fixture.number) == nil)
        #expect(try ViewQuery.open(fixture.base.viewId, in: fixture.store)?.result.rowIds == fixture.rows)
    }

    @Test("⌘V одного значения в выделенный прямоугольник — во все его ячейки")
    func pasteFillsSelection() throws {
        let fixture = try Fixture()
        var selection = CellSelection(CellPosition(row: 0, column: 1))
        selection.extend(to: CellPosition(row: 1, column: 1))
        let plan = CellClipboard.pastePlan([["3"]], at: selection, rowIds: fixture.rows, contexts: try fixture.contexts)
        #expect(plan.appendedRows == 0)
        #expect(plan.writes == fixture.rows.map { CellWrite(row: .existing($0), propertyId: fixture.number.id, value: .number(3)) })
    }

    @Test("⌫ стирает выделенные ячейки, у названия — пустое название")
    func erase() throws {
        let fixture = try Fixture()
        fixture.operations.undoManager = nil
        try fixture.operations.setCell(rowId: fixture.rows[0], propertyId: fixture.number.id, value: .number(4))
        var selection = CellSelection(CellPosition(row: 0, column: 0))
        selection.extend(to: CellPosition(row: 0, column: 1))
        let writes = CellClipboard.eraseWrites(selection, rowIds: fixture.rows, contexts: try fixture.contexts)
        try fixture.operations.writeCells(writes, appendingRows: 0, to: fixture.base.databaseId, in: fixture.base.viewId)
        #expect(try fixture.title(fixture.rows[0]) == "")
        #expect(try fixture.value(fixture.rows[0], fixture.number) == nil)
    }
}
