import Foundation
import GRDB
import Testing
@testable import Databases
@testable import NotesCore

/// Фоновый пересчёт формул (R21, T006): итоги сходятся с подсчётом «в лоб»; пачка не затирает строку, поправленную
/// после чтения; правка строки пересчитывает её в своей транзакции.
@Suite("Фоновый пересчёт формул")
struct BackgroundRecomputeTests {
    let folder: URL
    let store: NotesStore
    let sample: DatabaseSampleGenerator.Sample
    let now = Date()

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("recompute-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = NotesStore(database: try AppDatabase.open(at: folder.appendingPathComponent("MyNotion.sqlite")), clock: HybridLogicalClock(deviceId: UUID()))
        sample = try DatabaseSampleGenerator(taskCount: 300, projectCount: 20).ensure(in: store)
    }

    func computed(_ row: UUID, _ name: String) throws -> JSONValue? {
        try store.database.dbWriter.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM db_computed WHERE rowId = ? AND propertyId = ?",
                                arguments: [row.databaseText, sample.taskProperties[name]!.databaseText]).flatMap(FastJSON.parse)
        }
    }

    @Test("Полный пересчёт: «Итог», «Дней до срока», «Проект (имя)» — как подсчёт «в лоб»")
    func matchesBruteForce() throws {
        try store.database.dbWriter.write { try $0.execute(sql: "DELETE FROM db_computed WHERE propertyId IN (?, ?, ?)",
                                                           arguments: StatementArguments(["Итог", "Дней до срока", "Проект (имя)"].map { sample.taskProperties[$0]!.databaseText })) }
        let fixedNow = now
        let report = try FormulaRecompute(store: store, databaseId: sample.tasksId, now: { fixedNow }).recomputeAll(readBatch: 70, writeBatch: 25)
        #expect(report.rows == 300 && report.written == 900 && report.retried == 0)
        #expect(report.writeBatches == 13, "пачки по 25 строк внутри чтений по 70: 4 × 3 + 1")
        let rows = try ViewQuery.open(sample.tableViewId, in: store)!.result.rowIds
        for row in rows {
            let (done, deadline, project) = try store.write { tx throws in
                (try tx.cell(rowId: row, propertyId: sample.taskProperties["Сделано"]!)?.value?.bool ?? false,
                 try tx.cell(rowId: row, propertyId: sample.taskProperties["Срок"]!)?.value,
                 try tx.relationLinks(propertyId: sample.taskProperties["Проект"]!, rowId: row).first.flatMap { try tx.page($0.targetRowId)?.title })
            }
            #expect(try computed(row, "Итог") == .string(done ? "Готово" : "В работе"))
            let days = Calendar.current.dateComponents([.day], from: fixedNow, to: DateValues.start(deadline)!).day!
            #expect(try computed(row, "Дней до срока") == .number(Double(days)))
            #expect(try computed(row, "Проект (имя)") == .array([.string(project!)]))
        }
    }

    @Test("Пачка не затирает строку, поправленную после чтения; правка пересчитывает свою строку")
    func skipsRowsEditedAfterRead() throws {
        let rows = try ViewQuery.open(sample.tableViewId, in: store)!.result.rowIds
        let recompute = try FormulaRecompute(store: store, databaseId: sample.tasksId)
        let row = rows[0], done = sample.taskProperties["Сделано"]!, result = sample.taskProperties["Итог"]!
        // Прочитали и вычислили со старым флажком…
        let (values, stamps) = try store.database.dbWriter.read { db in
            let inputs = try FormulaInputs(rows: [row], needed: [done.databaseText], catalog: try DatabaseCatalog.read(sample.tasksId, in: db),
                                           now: Date(), calendar: .current, in: db)
            return (recompute.evaluate([row], inputs: inputs), try ComputedWriter.rowStamps([row], in: db))
        }
        // …а тем временем строку поправили — правка пересчитала свои итоги в своей транзакции.
        let old = try store.write { tx in try tx.cell(rowId: row, propertyId: done)?.value?.bool ?? false }
        Thread.sleep(forTimeInterval: 0.01)
        try store.write { tx throws in
            try tx.setCell(rowId: row, propertyId: done, value: .bool(!old))
            try recompute.recompute(rows: [row], in: tx)
        }
        let fresh = try computed(row, "Итог")
        #expect(fresh == .string(!old ? "Готово" : "В работе"))
        let skipped = try store.database.dbWriter.write { db in try ComputedWriter.write(values, readStamps: stamps, in: db) }
        #expect(skipped == [row])
        #expect(try computed(row, "Итог") == fresh, "старый итог не вернулся")
        _ = result
    }

    @Test("Пачка не затирает итог, который правка строки другой базы пересчитала после чтения (своя строка не менялась)")
    func skipsRowsRecomputedThroughRelation() throws {
        let rows = try ViewQuery.open(sample.tableViewId, in: store)!.result.rowIds
        let recompute = try FormulaRecompute(store: store, databaseId: sample.tasksId)
        let row = rows[0], relation = sample.taskProperties["Проект"]!, title = sample.projectProperties["Название"]!
        let project = try #require(try store.write { tx in try tx.relationLinks(propertyId: relation, rowId: row).first?.targetRowId })
        // Прочитали и вычислили «Проект (имя)» со старым названием проекта…
        let (values, stamps) = try store.database.dbWriter.read { db in
            let inputs = try FormulaInputs(rows: [row], needed: [relation.databaseText, title.databaseText],
                                           catalog: try DatabaseCatalog.read(sample.tasksId, in: db), now: Date(), calendar: .current, in: db)
            return (recompute.evaluate([row], inputs: inputs), try ComputedWriter.rowStamps([row], in: db))
        }
        // …а тем временем проект переименовали — правка пересчитала итог задачи в своей транзакции; сама задача не менялась.
        try store.write { tx throws in
            var page = try #require(try tx.page(project))
            page.title = "Новое имя"
            try tx.updatePage(page)
            try recompute.recompute(rows: [row], in: tx)
        }
        #expect(try computed(row, "Проект (имя)") == .array(["Новое имя"]))
        let skipped = try store.database.dbWriter.write { db in try ComputedWriter.write(values, readStamps: stamps, in: db) }
        #expect(skipped == [row])
        #expect(try computed(row, "Проект (имя)") == .array(["Новое имя"]), "старое имя не вернулось")
    }
}
