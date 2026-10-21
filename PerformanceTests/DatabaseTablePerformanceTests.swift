import AppKit
import DatabaseGrid
import DatabaseViewBar
import Databases
import NotesCore
import XCTest

/// Замеры таблицы US1 (T045, SC-301, SC-303, SC-305) на эталоне баз: «Задачи» — 10 000 строк, 30 свойств, окно 1440×900.
/// Открытие таблицы (контроллер вида, сетка, первый экран) p95 ≤ 50 мс; правка текста и флажка до нарисованной строки
/// p95 ≤ 50 мс; смена типа свойства на 10 000 строках ≤ 2 с (одним шагом отмены, ⌘Z возвращает значения).
@MainActor
final class DatabaseTablePerformanceTests: XCTestCase {
    static let budgetMs = 50.0
    static let typeChangeBudgetMs = 2_000.0

    func testTasksTableOpenEditAndTypeChangeWithinBudget() throws {
        let library = try DatabaseProbeLibrary.copy()
        defer { library.store.database.close(); try? FileManager.default.removeItem(at: library.folder) }
        let store = library.store, sample = library.sample
        store.addWriteHook(CellIndexer())
        let undo = UndoManager()
        undo.groupsByEvent = false
        let operations = DatabaseOperations(store: store, undoManager: undo)
        let window = DatabaseProbeWindow()
        defer { window.close() }

        // Открытие: запрос вида, сетка с колонками, первый экран нарисован.
        var opens: [Double] = []
        var table: DatabaseTableView!
        for round in 0..<12 {
            window.show(NSView())
            window.render()
            window.pump(10)
            let ms = try ProbeEditor.measure {
                let controller = try XCTUnwrap(DatabaseTableController(store: store, operations: operations, databaseId: sample.tasksId,
                                                                       viewId: sample.tableViewId))
                table = DatabaseTableView(controller: controller, mode: .page)
                window.show(table)
                window.render()
            }
            if round >= 2 { opens.append(ms) }
        }
        window.pump(300)
        XCTAssertEqual(table.controller.content.rowIds.count, DatabaseSampleGenerator.taskCount)
        let shot = try XCTUnwrap(DatabaseProbeShots.snapshot(window.window.contentView!))
        let shotPath = DatabaseProbeShots.save(shot, name: "us1-задачи-открыта", to: self)

        // Правка текста: значение записано, строка перечитана и нарисована.
        let columns = table.controller.content.columns
        let text = try XCTUnwrap(columns.firstIndex { $0.property.id == sample.taskProperties["Описание"] })
        let check = try XCTUnwrap(columns.firstIndex { $0.property.id == sample.taskProperties["Сделано"] })
        var edits: [Double] = [], toggles: [Double] = []
        for round in 0..<30 {
            let row = 3 + round % 10
            let ms = ProbeEditor.measure {
                undo.beginUndoGrouping()
                table.controller.commitText("правка \(round)", row: row, column: text)
                undo.endUndoGrouping()
                window.render()
            }
            let toggle = ProbeEditor.measure {
                undo.beginUndoGrouping()
                table.controller.toggleCheckbox(row: row, column: check)
                undo.endUndoGrouping()
                window.render()
            }
            if round >= 3 { edits.append(ms); toggles.append(toggle) }
            window.pump(5)
        }
        let edited = try store.write { try $0.cell(rowId: table.controller.content.rowIds[3], propertyId: sample.taskProperties["Описание"]!)?.value }
        XCTAssertEqual(edited?["string"]?.string, "правка 20")

        // Смена типа «Часы» (число, значение у каждой строки) → «Текст» на 10 000 строках: время и ⌘Z.
        let note = try XCTUnwrap(sample.taskProperties["Часы"])
        let before = try store.write { try $0.cell(rowId: table.controller.content.rowIds[7], propertyId: note)?.value }
        undo.beginUndoGrouping()
        let typeChange = try ProbeEditor.measure { try operations.changeType(note, to: .text) }
        undo.endUndoGrouping()
        window.render()
        undo.undo()
        let restored = try store.write { try $0.cell(rowId: table.controller.content.rowIds[7], propertyId: note)?.value }
        XCTAssertEqual(restored, before, "⌘Z не вернул значение после смены типа")

        let summary = """
            Таблица US1: открытие «Задачи» p95 \(ProbeEditor.format(ProbeEditor.p95(opens))) мс (предел 50); правка текста \
            p95 \(ProbeEditor.format(ProbeEditor.p95(edits))) мс, флажок p95 \(ProbeEditor.format(ProbeEditor.p95(toggles))) мс (предел 50); \
            смена типа на 10 000 строк \(ProbeEditor.format(typeChange)) мс (предел 2000)
            Снимок: \(shotPath)
            """
        print(summary)
        add(XCTAttachment(string: summary))
        XCTAssertLessThanOrEqual(ProbeEditor.p95(opens), Self.budgetMs, "Открытие «Задачи»: p95 больше 50 мс")
        XCTAssertLessThanOrEqual(ProbeEditor.p95(edits), Self.budgetMs, "Правка текста: p95 больше 50 мс")
        XCTAssertLessThanOrEqual(ProbeEditor.p95(toggles), Self.budgetMs, "Флажок: p95 больше 50 мс")
        XCTAssertLessThanOrEqual(typeChange, Self.typeChangeBudgetMs, "Смена типа на 10 000 строк дольше 2 с")
    }
}
