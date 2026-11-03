import Foundation
import GRDB
import Testing
@testable import Databases
@testable import NotesCore

/// Находка ревью №4 (T113): правка строки, которую по связи читают сотни строк другой базы, не ждёт их пересчёта —
/// он уходит в фоновую очередь (замер: проект на 1 000 задач — p95 до 179 мс при бюджете 50). Немного читателей —
/// по-прежнему в той же записи. Читатели читателей пересчитываются в фоне следом.
@MainActor
@Suite("Пересчёт: много читателей связи — в фоне")
struct LinkedReadersBackgroundTests {
    let folder: URL
    let store: NotesStore
    let queue: FormulaRecomputeQueue
    let operations: DatabaseOperations

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("readers-bg-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = NotesStore(database: try AppDatabase.open(at: folder.appendingPathComponent("MyNotion.sqlite")), clock: HybridLogicalClock(deviceId: UUID()))
        queue = FormulaRecomputeQueue(store: store)
        operations = DatabaseOperations(store: store)
    }

    func sample(tasks: Int, projects: Int) throws -> DatabaseSampleGenerator.Sample {
        let sample = try DatabaseSampleGenerator(taskCount: tasks, projectCount: projects).ensure(in: store)
        store.addWriteHook(CellIndexer())
        store.addWriteHook(ComputationHook(store: store, queue: queue))
        return sample
    }

    func computed(_ row: UUID, _ property: UUID) throws -> JSONValue? {
        try store.database.dbWriter.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM db_computed WHERE rowId = ? AND propertyId = ?",
                                arguments: [row.databaseText, property.databaseText]).flatMap(FastJSON.parse)
        }
    }

    func rows(of databaseId: UUID) throws -> [UUID] {
        try store.database.dbWriter.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM page WHERE parentId = ? AND trashedAt IS NULL ORDER BY sortKey",
                                arguments: [databaseId.databaseText]).compactMap(UUID.init(uuidString:))
        }
    }

    func rename(_ row: UUID, _ title: String) throws {
        try store.write { tx throws in
            var page = try #require(try tx.page(row))
            page.title = title
            try tx.updatePage(page)
        }
    }

    /// Занять очередь: пока не отпущена, фоновый пересчёт не начнётся.
    func holdQueue() -> DispatchSemaphore {
        let blocked = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        queue.enqueueBarrier { blocked.signal(); release.wait() }
        blocked.wait()
        return release
    }

    @Test("Проект, который читают 300 задач: правка не пересчитывает их в своей записи, фон — пересчитывает, и читателей задач тоже")
    func manyReadersGoToBackground() throws {
        let sample = try sample(tasks: 300, projects: 1)
        let tasks = try rows(of: sample.tasksId), project = try #require(try rows(of: sample.projectsId).first)
        let name = sample.taskProperties["Проект (имя)"]!
        // Читатель читателей: сводка проекта по «Проект (имя)» его задач.
        let names = try operations.addProperty(to: sample.projectsId, name: "Имена в задачах", kind: .rollup).id
        try operations.setRollup(names, relation: sample.projectProperties["Задачи"]!, target: name, calculation: .showUnique)
        queue.waitUntilIdle()
        let before = try computed(tasks[0], name)
        #expect(try computed(project, names) != nil)

        let release = holdQueue()
        try rename(project, "Новое имя")
        #expect(try computed(tasks[0], name) == before, "300 читателей — не в записи правки")
        release.signal()
        queue.waitUntilIdle()
        #expect(try tasks.allSatisfy { try computed($0, name) == .array(["Новое имя"]) })
        #expect(try String(describing: computed(project, names)).contains("Новое имя"), "читатель читателей пересчитан следом")
    }

    @Test("Проект, который читают 20 задач, — пересчёт в той же записи, без очереди")
    func fewReadersStayInTransaction() throws {
        let sample = try sample(tasks: 40, projects: 2)
        let tasks = try rows(of: sample.tasksId), project = try #require(try rows(of: sample.projectsId).first)
        let name = sample.taskProperties["Проект (имя)"]!
        let linked = try store.write { tx throws in
            try tasks.filter { try tx.relationLinks(propertyId: sample.taskProperties["Проект"]!, rowId: $0).contains { $0.targetRowId == project } }
        }
        #expect(linked.count == 20)

        let release = holdQueue()
        defer { release.signal(); queue.waitUntilIdle() }
        try rename(project, "Новое имя")
        #expect(try linked.allSatisfy { try computed($0, name) == .array(["Новое имя"]) })
    }
}
