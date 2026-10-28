import Foundation
import GRDB
import Testing
@testable import NotesCore

/// Миграция v12 (008): добавочные таблицы чатов ИИ-агента `ai_chat` и `ai_chat_message` — прежние таблицы не меняются,
/// база v11 до неё сохраняется копией `MyNotion.backup-v11.sqlite`.
@Suite("Миграция v11 → v12")
struct DatabaseMigrationV12Tests {
    @Test("База v11 → v12: страницы те же, старые таблицы те же, добавились таблицы чатов; копия v11 рядом")
    func addsChatTables() throws {
        let folder = try TemporaryFolder()
        let v11 = try AppDatabase.open(at: folder.databaseURL, migrations: DatabaseMigrationV11Tests.upToV11)
        try v11.dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO page (id, title, sortKey, createdAt, updatedAt, fieldClocks)
                VALUES (?, 'Страница', 'm', '2026-10-01 10:00:00', '2026-10-01 10:00:00', '{}')
                """, arguments: [UUID.timeOrdered().databaseText])
        }
        let before = try Self.tables(v11)
        let pagesBefore = try v11.dbWriter.read { try Row.fetchAll($0, sql: "SELECT * FROM page") }
        v11.close()

        let database = try AppDatabase.open(at: folder.databaseURL)
        defer { database.close() }
        #expect(try database.appliedSchemaVersion() == "v12")
        let after = try Self.tables(database)
        #expect(Set(after.keys).subtracting(before.keys) == ["ai_chat", "ai_chat_message"])
        for (name, sql) in before { #expect(after[name] == sql, "таблица \(name) не поменялась") }
        #expect(try database.dbWriter.read { try Row.fetchAll($0, sql: "SELECT * FROM page") } == pagesBefore)
        #expect(FileManager.default.fileExists(atPath: AppDatabase.backupURL(for: folder.databaseURL, version: "v11").path))
    }

    private static func tables(_ database: AppDatabase) throws -> [String: String] {
        try database.dbWriter.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT name, sql FROM sqlite_master WHERE type = 'table' AND name != 'grdb_migrations'")
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["name"] as String, $0["sql"] as String) })
        }
    }
}
