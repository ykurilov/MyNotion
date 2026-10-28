import Foundation
import GRDB
import Testing
@testable import NotesCore

/// Миграция v11 (006): добавочная таблица ссылок `page_share` — страницы и прочие таблицы не меняются,
/// база v10 до неё сохраняется копией `MyNotion.backup-v10.sqlite`.
@Suite("Миграция v10 → v11")
struct DatabaseMigrationV11Tests {
    static let upToV10 = SchemaMigrations(steps: Array(SchemaMigrations.current.steps.prefix { $0.version != "v11" }))
    static let upToV11 = SchemaMigrations(steps: Array(SchemaMigrations.current.steps.prefix { $0.version != "v12" }))

    @Test("База v10 → v11: страницы те же, старые таблицы те же, добавилась page_share; копия v10 рядом")
    func addsPageShareTable() throws {
        let folder = try TemporaryFolder()
        let v10 = try AppDatabase.open(at: folder.databaseURL, migrations: Self.upToV10)
        try v10.dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO page (id, title, sortKey, createdAt, updatedAt, fieldClocks)
                VALUES (?, 'Страница', 'm', '2026-10-01 10:00:00', '2026-10-01 10:00:00', '{}')
                """, arguments: [UUID.timeOrdered().databaseText])
        }
        let before = try Self.tables(v10)
        let pagesBefore = try v10.dbWriter.read { try Row.fetchAll($0, sql: "SELECT * FROM page") }
        v10.close()

        let database = try AppDatabase.open(at: folder.databaseURL, migrations: Self.upToV11)
        defer { database.close() }
        #expect(try database.appliedSchemaVersion() == "v11")
        let after = try Self.tables(database)
        #expect(Set(after.keys).subtracting(before.keys) == ["page_share"])
        for (name, sql) in before { #expect(after[name] == sql, "таблица \(name) не поменялась") }
        #expect(try database.dbWriter.read { try Row.fetchAll($0, sql: "SELECT * FROM page") } == pagesBefore)
        #expect(FileManager.default.fileExists(atPath: AppDatabase.backupURL(for: folder.databaseURL, version: "v10").path))

        try database.dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO page_share (pageId, token, enabled, includeSubpages, publishedDigest, updatedAt)
                VALUES ('p', 't', 1, 1, NULL, '2026-10-25 10:00:00')
                """)
        }
    }

    private static func tables(_ database: AppDatabase) throws -> [String: String] {
        try database.dbWriter.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT name, sql FROM sqlite_master WHERE type = 'table' AND name != 'grdb_migrations'")
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["name"] as String, $0["sql"] as String) })
        }
    }
}
