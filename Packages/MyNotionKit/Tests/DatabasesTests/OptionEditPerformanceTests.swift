import Foundation
import Reminders
import Testing
@testable import Databases
@testable import NotesCore

/// Замер US2 (T075): правка ячейки выбора (выбрать вариант, создать по Enter, множественный — добавить) и даты
/// (с напоминанием) на эталоне «Задачи» 10 000 строк — p95 ≤ 50 мс на правку с транзакцией, индексом и шагом отмены
/// (бюджет правки ячейки, quickstart.md). Долгий: включается `MYNOTION_PERF=1`.
@MainActor
@Suite("Базы: замер правки выбора и даты (US2)", .enabled(if: ProcessInfo.processInfo.environment["MYNOTION_PERF"] != nil))
struct OptionEditPerformanceTests {
    @Test("Выбор, множественный выбор, Enter с новым вариантом, дата с напоминанием — p95 ≤ 50 мс")
    func cellEdits() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("us2-perf-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = NotesStore(database: try AppDatabase.open(at: folder.appendingPathComponent("MyNotion.sqlite")), clock: HybridLogicalClock(deviceId: UUID()))
        store.addWriteHook(CellIndexer())
        store.addWriteHook(ReminderIndexer { _ in })
        let sample = try DatabaseSampleGenerator().ensure(in: store)
        let undo = UndoManager()
        let operations = DatabaseOperations(store: store, undoManager: undo)
        let rows = try #require(try ViewQuery.open(sample.tableViewId, in: store)).result.rowIds
        let priority = try #require(sample.taskProperties["Приоритет"])
        let tags = try #require(sample.taskProperties["Теги"])
        let due = try #require(sample.taskProperties["Срок"])
        let priorityOptions = try DatabaseCatalog.read(sample.tasksId, in: store).options[priority] ?? []
        let tagOptions = try DatabaseCatalog.read(sample.tasksId, in: store).options[tags] ?? []

        func measure(_ name: String, _ body: (Int) throws -> Void) rethrows -> Double {
            var times: [Double] = []
            for index in 0..<60 {
                let start = DispatchTime.now().uptimeNanoseconds
                try body(index)
                times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            }
            let sorted = times.sorted()
            let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
            print("US2 замер — \(name): p50 \(String(format: "%.1f", sorted[sorted.count / 2])) мс, p95 \(String(format: "%.1f", p95)) мс, худший \(String(format: "%.1f", sorted.last!)) мс")
            return p95
        }

        let pick = try measure("выбор варианта") { index in
            try operations.pickOption(priorityOptions[index % priorityOptions.count].id, rowId: rows[index * 97 % rows.count], propertyId: priority)
        }
        let multi = try measure("множественный: добавить вариант") { index in
            try operations.pickOption(tagOptions[index % tagOptions.count].id, rowId: rows[index * 89 % rows.count], propertyId: tags)
        }
        let create = try measure("Enter: новый вариант и выбор") { index in
            _ = try operations.pickOption(named: "Новый \(index)", rowId: rows[index * 71 % rows.count], propertyId: priority)
        }
        let date = try measure("дата с концом и напоминанием") { index in
            let value: JSONValue = ["start": .string(String(format: "2030-%02d-%02dT10:00", index % 12 + 1, index % 28 + 1)),
                                    "end": .string(String(format: "2030-%02d-%02dT18:00", index % 12 + 1, index % 28 + 1)),
                                    "hasTime": true, "timeZone": "Europe/Moscow", "reminder": "hour1"]
            try operations.setCell(rowId: rows[index * 53 % rows.count], propertyId: due, value: value)
        }
        #expect(pick <= 50)
        #expect(multi <= 50)
        #expect(create <= 50)
        #expect(date <= 50)
    }
}
