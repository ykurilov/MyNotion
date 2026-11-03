import Foundation
import Testing
@testable import Databases
@testable import NotesCore

/// Замер находки ревью №4 (T113): правка проекта, который читают сводки и формулы его задач, пересчитывает их в
/// транзакции правки. Эталон 10 000 задач ↔ 500 проектов; в проект 1 переносятся 200 (предел пересчёта в записи),
/// 1 000, 5 000 и 10 000 задач (больше предела — пересчёт читателей в фоне, правка его не ждёт);
/// правка «Срока» проекта (его читает сводка «Срок проекта») и названия (его читает «Проект (имя)»).
/// Бюджет правки ячейки — p95 ≤ 50 мс (SC-303). Долгий: включается `MYNOTION_PERF=1`.
@MainActor
@Suite("Базы: замер пересчёта читателей связи", .enabled(if: ProcessInfo.processInfo.environment["MYNOTION_PERF"] != nil))
struct LinkedReadersPerformanceTests {
    @Test("Правка проекта на 1 000 / 5 000 / 10 000 задач — p50 и p95")
    func editOfProjectReadByManyTasks() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("readers-perf-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = NotesStore(database: try AppDatabase.open(at: folder.appendingPathComponent("MyNotion.sqlite")), clock: HybridLogicalClock(deviceId: UUID()))
        let sample = try DatabaseSampleGenerator().ensure(in: store)
        let queue = FormulaRecomputeQueue(store: store)
        store.addWriteHook(CellIndexer())
        store.addWriteHook(ComputationHook(store: store, queue: queue))
        let operations = DatabaseOperations(store: store, undoManager: UndoManager())
        let relation = sample.taskProperties["Проект"]!, deadline = sample.projectProperties["Срок"]!
        let tasks = try #require(try ViewQuery.open(sample.tableViewId, in: store)).result.rowIds
        let projects = try store.database.dbWriter.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM page WHERE parentId = ? ORDER BY sortKey", arguments: [sample.projectsId.databaseText])
                .compactMap(UUID.init(uuidString:))
        }
        let big = projects[0]

        func measure(_ body: (Int) throws -> Void) rethrows -> (p50: Double, p95: Double) {
            var times: [Double] = []
            for index in 0..<25 {
                let start = DispatchTime.now().uptimeNanoseconds
                try body(index)
                if index >= 5 { times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6) }
            }
            let sorted = times.sorted()
            return (sorted[sorted.count / 2], sorted[Int(Double(sorted.count - 1) * 0.95)])
        }
        func format(_ value: Double) -> String { String(format: "%.1f", value) }

        var moved = 0
        for size in [ComputationHook.readersInTransactionLimit, 1_000, 5_000, 10_000] {
            // Подготовка без замера: задачи moved..<size переходят в проект 1 одной записью.
            try store.write { tx in
                for task in tasks[moved..<size] {
                    for link in try tx.relationLinks(propertyId: relation, rowId: task) where link.targetRowId != big {
                        var removed = link
                        removed.isPresent = false
                        try tx.saveRelationLink(removed)
                    }
                    try tx.saveRelationLink(RelationLink(propertyId: relation, rowId: task, targetRowId: big, sortKey: .between(nil, nil)))
                }
            }
            moved = size
            queue.waitUntilIdle()
            let date = try measure { index in
                let day = String(format: "2030-%02d-%02d", index % 12 + 1, index % 28 + 1)
                try operations.setCell(rowId: big, propertyId: deadline, value: ["start": .string(day), "hasTime": false])
            }
            let title = try measure { index in
                try store.write { tx throws in
                    var page = try #require(try tx.page(big))
                    page.title = "Проект 1, правка \(index)"
                    try tx.updatePage(page)
                }
            }
            print("Находка №4 — проект на \(size) задач: «Срок» p50 \(format(date.p50)) мс, p95 \(format(date.p95)) мс; "
                  + "название p50 \(format(title.p50)) мс, p95 \(format(title.p95)) мс (бюджет p95 ≤ 50 мс)")
        }
    }
}
