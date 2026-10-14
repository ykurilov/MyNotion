import Foundation
import GRDB
import Testing
@testable import NotesCore

@Suite("Схема базы и миграции")
struct DatabaseMigrationTests {
    @Test("Пустая база создаётся со всеми таблицами, в режиме WAL")
    func emptyDatabaseHasAllTables() throws {
        let folder = try TemporaryFolder()
        let database = try AppDatabase.open(at: folder.databaseURL)

        let (tables, journalMode, searchIndexSQL) = try database.dbWriter.read { db in
            (
                try String.fetchSet(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"),
                try String.fetchOne(db, sql: "PRAGMA journal_mode"),
                try String.fetchOne(db, sql: "SELECT sql FROM sqlite_master WHERE name = 'search_index'")
            )
        }

        let expected: Set = ["page", "block", "conflict", "window_state", "import_run", "sync_account", "outbox_entry", "search_index"]
        #expect(expected.isSubset(of: tables))
        #expect(journalMode == "wal")
        #expect(searchIndexSQL?.contains("fts5") == true)
        #expect(searchIndexSQL?.contains("unicode61 remove_diacritics 2") == true)
    }

    @Test("Новая база без копии: копировать нечего")
    func freshDatabaseMakesNoBackup() throws {
        let folder = try TemporaryFolder()
        _ = try AppDatabase.open(at: folder.databaseURL)

        let files = try FileManager.default.contentsOfDirectory(atPath: folder.url.path)
        #expect(!files.contains { $0.contains("backup") })
    }

    @Test("Перед миграцией рядом появляется копия MyNotion.backup-<версия>.sqlite, из неё база восстанавливается")
    func backupBeforeMigrationAndRestore() throws {
        let folder = try TemporaryFolder()
        let clock = HybridLogicalClock(deviceId: UUID(), wallClock: AdjustableWallClock().reading)

        let original = try AppDatabase.open(at: folder.databaseURL)
        let versionBefore = try #require(try original.appliedSchemaVersion())
        let page = try NotesStore(database: original, clock: clock).write { try $0.createPage(title: "До миграции") }
        original.close()

        let withNextVersion = SchemaMigrations.current.appending("test-rename-titles") { db in
            try db.execute(sql: "UPDATE page SET title = 'После миграции'")
        }
        let migrated = try AppDatabase.open(at: folder.databaseURL, migrations: withNextVersion)
        #expect(try NotesStore(database: migrated, clock: clock).pageOutline().first?.title == "После миграции")
        migrated.close()

        let backupURL = folder.url.appendingPathComponent("MyNotion.backup-\(versionBefore).sqlite")
        #expect(FileManager.default.fileExists(atPath: backupURL.path))

        try AppDatabase.restore(backup: backupURL, over: folder.databaseURL)

        let restored = try AppDatabase.open(at: folder.databaseURL)
        let pages = try NotesStore(database: restored, clock: clock).pageOutline()
        #expect(pages.map(\.id) == [page.id])
        #expect(pages.first?.title == "До миграции")
        #expect(try restored.appliedSchemaVersion() == versionBefore)
    }

    @Test("Основная база живёт в ~/Library/Application Support/MyNotion/MyNotion.sqlite")
    func defaultLocation() {
        #expect(AppDatabase.defaultURL.path.hasSuffix("Library/Application Support/MyNotion/MyNotion.sqlite"))
    }
}
