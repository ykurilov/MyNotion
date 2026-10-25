import Foundation
import GRDB
import Testing
@testable import NotesCore

/// Миграция v10 (T085): только добавочный индекс живых строк `page_live_by_parent` — данные и синхронизируемая схема
/// не меняются, база v9 до неё сохраняется копией `MyNotion.backup-v9.sqlite`.
@Suite("Миграция v9 → v10")
struct DatabaseMigrationV10Tests {
    static let upToV9 = SchemaMigrations(steps: Array(SchemaMigrations.current.steps.prefix { $0.version != "v10" }))
    static let upToV10 = SchemaMigrations(steps: Array(SchemaMigrations.current.steps.prefix { $0.version != "v11" }))

    @Test("База v9 → v10: страницы те же, таблицы те же, добавился один индекс; копия v9 рядом")
    func addsOnlyLiveRowsIndex() throws {
        let folder = try TemporaryFolder()
        let parentId = UUID.timeOrdered()
        let v9 = try AppDatabase.open(at: folder.databaseURL, migrations: Self.upToV9)
        #expect(try v9.appliedSchemaVersion() == "v9")
        try v9.dbWriter.write { db in
            for (index, id) in [parentId, UUID.timeOrdered(), UUID.timeOrdered()].enumerated() {
                let parent: String? = index == 0 ? nil : parentId.databaseText
                let trashedAt: String? = index == 2 ? "2026-10-02 10:00:00" : nil
                try db.execute(sql: """
                    INSERT INTO page (id, title, parentId, sortKey, createdAt, updatedAt, fieldClocks, trashedAt, isTemplate)
                    VALUES (?, ?, ?, ?, '2026-10-01 10:00:00', '2026-10-01 10:00:00', '{}', ?, ?)
                    """, arguments: [id.databaseText, "Страница \(index)", parent, "m\(index)", trashedAt, index == 1])
            }
        }
        let before = try Self.dump(v9)
        v9.close()

        let database = try AppDatabase.open(at: folder.databaseURL, migrations: Self.upToV10)
        defer { database.close() }
        #expect(try database.appliedSchemaVersion() == "v10")
        let after = try Self.dump(database)
        #expect(after.pages == before.pages, "строки страниц не изменились")
        #expect(after.tables == before.tables, "ни одна таблица не поменялась")
        #expect(after.indexes.subtracting(before.indexes) == ["page_live_by_parent"])
        #expect(before.indexes.isSubset(of: after.indexes))
        #expect(FileManager.default.fileExists(atPath: AppDatabase.backupURL(for: folder.databaseURL, version: "v9").path))
    }

    private struct Dump {
        let pages: [[String]]
        let tables: [String]
        let indexes: Set<String>
    }

    private static func dump(_ database: AppDatabase) throws -> Dump {
        try database.dbWriter.read { db -> Dump in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM page ORDER BY id")
            let pages: [[String]] = rows.map { row in row.databaseValues.map { (value: DatabaseValue) -> String in value.description } }
            let tables = try String.fetchAll(db, sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name != 'grdb_migrations' ORDER BY name")
            let indexes = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND sql IS NOT NULL")
            return Dump(pages: pages, tables: tables, indexes: Set(indexes))
        }
    }
}
