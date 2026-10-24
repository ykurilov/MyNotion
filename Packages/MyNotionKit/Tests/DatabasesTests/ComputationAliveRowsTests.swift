import Foundation
import GRDB
import Testing
@testable import Databases
@testable import NotesCore

@Suite("Живые строки пересчёта")
struct ComputationAliveRowsTests {
    /// Реальная схема, 10 000 строк одного родителя: индекс parentId здесь особенно невыгоден.
    func fixture() throws -> (DatabaseQueue, UUID, [UUID]) {
        let queue = try DatabaseQueue()
        try SchemaMigrations.current.migrator.migrate(queue)
        let parent = UUID()
        let rows = (0..<10_000).map { _ in UUID() }
        try queue.write { db in
            let insert = try db.makeStatement(sql: """
                INSERT INTO page(id, title, parentId, sortKey, createdAt, updatedAt, fieldClocks)
                VALUES (?, '', ?, 'a', 0, 0, '{}')
                """)
            for row in rows {
                try insert.execute(arguments: [row.databaseText, parent.databaseText])
            }
        }
        return (queue, parent, rows)
    }

    @Test("Пачки сохраняют родителя, корзину, шаблоны и уникальность IN")
    func batchesAndPredicates() throws {
        let (queue, parent, rows) = try fixture()
        let selected = Array(rows.prefix(1_003))
        try queue.write { db in
            try db.execute(sql: "UPDATE page SET parentId = ? WHERE id = ?", arguments: [UUID().databaseText, selected[0].databaseText])
            try db.execute(sql: "UPDATE page SET trashedAt = 1 WHERE id = ?", arguments: [selected[1].databaseText])
            try db.execute(sql: "UPDATE page SET isTemplate = 1 WHERE id = ?", arguments: [selected[2].databaseText])
            let actual = try ComputationHook.aliveRows(selected + selected + [UUID()], of: parent, in: db)
            #expect(Set(actual) == Set(selected.dropFirst(2)))
            #expect(actual.count == selected.count - 2, "дубликаты между пачками не возвращаются")
            #expect(try ComputationHook.aliveRows([], of: parent, in: db).isEmpty)
            #expect(try ComputationHook.aliveRows(selected, of: UUID(), in: db).isEmpty)
        }
    }

    @Test("План ищет по id, а не перебирает строки родителя")
    func primaryKeyPlan() throws {
        let (queue, parent, rows) = try fixture()
        try queue.read { db in
            for count in [1, ComputationHook.aliveRowsBatchSize] {
                let plan = try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + ComputationHook.aliveRowsSQL(rowCount: count),
                                            arguments: StatementArguments([parent.databaseText] + rows.prefix(count).map(\.databaseText)))
                    .map { $0["detail"] as String }
                #expect(plan.contains { $0.contains("SEARCH page") && $0.contains("id=?") }, "поиск по PK: \(plan)")
                #expect(!plan.contains { $0.contains("SCAN page") || $0.contains("parentId=?") }, "без прохода по родителю: \(plan)")
            }
        }
    }
}
