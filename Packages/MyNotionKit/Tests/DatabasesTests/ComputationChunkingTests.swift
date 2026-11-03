import Foundation
import GRDB
import SQLite3
import Testing
@testable import Databases
@testable import NotesCore

/// Пересчёт в транзакции правки не упирается в предел параметров SQLite: тысяча строк, связанных с одной, читается
/// пачками (старые сборки SQLite — 999 параметров в запросе).
@MainActor
@Suite("Пересчёт: пачки запросов")
struct ComputationChunkingTests {
    let folder: URL
    let store: NotesStore
    let sample: DatabaseSampleGenerator.Sample
    let systemLimit: Int32

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("chunking-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = NotesStore(database: try AppDatabase.open(at: folder.appendingPathComponent("MyNotion.sqlite")), clock: HybridLogicalClock(deviceId: UUID()))
        sample = try DatabaseSampleGenerator(taskCount: 1_100, projectCount: 1).ensure(in: store)
        store.addWriteHook(CellIndexer())
        store.addWriteHook(ComputationHook(store: store, queue: nil))
        systemLimit = try store.database.dbWriter.write { db in
            let previous = sqlite3_limit(db.sqliteConnection, SQLITE_LIMIT_VARIABLE_NUMBER, 999)
            return previous
        }
        print("Предел параметров SQLite в системе: \(systemLimit); в тесте — 999")
    }

    func computed(_ row: UUID, _ property: UUID) throws -> JSONValue? {
        try store.database.dbWriter.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM db_computed WHERE rowId = ? AND propertyId = ?",
                                arguments: [row.databaseText, property.databaseText]).flatMap(FastJSON.parse)
        }
    }

    var project: UUID {
        get throws {
            try #require(try store.database.dbWriter.read { db in
                try String.fetchOne(db, sql: "SELECT id FROM page WHERE parentId = ? AND trashedAt IS NULL", arguments: [sample.projectsId.databaseText])
            }.flatMap(UUID.init(uuidString:)))
        }
    }

    @Test("Часы у 1100 задач одной записью — сводка проекта и формулы задач пересчитаны")
    func bulkEditOfManyLinkedRows() throws {
        let rows = try ViewQuery.open(sample.tableViewId, in: store)!.result.rowIds
        #expect(rows.count == 1_100)
        let hours = sample.taskProperties["Часы"]!
        try store.write { tx throws in try tx.setCells(rows.map { ($0, JSONValue.number(1)) }, propertyId: hours) }
        #expect(try computed(project, sample.projectProperties["Сумма часов"]!) == 1_100)
    }

    @Test("Переименование проекта, который читают 1100 задач, — «Проект (имя)» у всех новое")
    func renameOfTargetReadByManyRows() throws {
        let rows = try ViewQuery.open(sample.tableViewId, in: store)!.result.rowIds
        let project = try project
        try store.write { tx throws in
            var page = try #require(try tx.page(project))
            page.title = "Новое имя"
            try tx.updatePage(page)
        }
        let name = sample.taskProperties["Проект (имя)"]!
        #expect(try computed(rows[0], name) == .array(["Новое имя"]))
        #expect(try computed(rows[rows.count - 1], name) == .array(["Новое имя"]))
    }
}
