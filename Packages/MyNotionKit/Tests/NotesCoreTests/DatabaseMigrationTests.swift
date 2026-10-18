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

        let expected: Set = ["page", "block", "conflict", "window_state", "import_run", "sync_account", "outbox_entry", "search_index", "page_tombstone"]
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

    @Test("v1 → v2: записи на месте, появилась таблица надгробий, рядом копия v1")
    func migrationAddsPageTombstones() throws {
        let folder = try TemporaryFolder()
        let clock = HybridLogicalClock(deviceId: UUID(), wallClock: AdjustableWallClock().reading)
        let onlyV1 = SchemaMigrations(steps: Array(SchemaMigrations.current.steps.prefix(1)))

        let old = try AppDatabase.open(at: folder.databaseURL, migrations: onlyV1)
        let page = try NotesStore(database: old, clock: clock).write { try $0.createPage(title: "Старая запись") }
        old.close()

        let migrated = try AppDatabase.open(at: folder.databaseURL)
        #expect(try migrated.appliedSchemaVersion() == SchemaMigrations.current.steps.last?.version)
        #expect(try NotesStore(database: migrated, clock: clock).pageOutline().map(\.title) == ["Старая запись"])
        #expect(try NotesStore(database: migrated, clock: clock).pageContent(page.id)?.blocks.count == 1)
        let hasTombstones = try migrated.dbWriter.read { db in try db.tableExists("page_tombstone") }
        #expect(hasTombstones)
        #expect(FileManager.default.fileExists(atPath: AppDatabase.backupURL(for: folder.databaseURL, version: "v1").path))
    }

    @Test("v2 → v3: сохранённый вид окна на месте, боковая панель открыта")
    func migrationAddsSidebarCollapsed() throws {
        let folder = try TemporaryFolder()
        let clock = HybridLogicalClock(deviceId: UUID(), wallClock: AdjustableWallClock().reading)
        let onlyV2 = SchemaMigrations(steps: Array(SchemaMigrations.current.steps.prefix(2)))
        let pageId = UUID.timeOrdered()

        let old = try AppDatabase.open(at: folder.databaseURL, migrations: onlyV2)
        try old.dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO window_state (windowId, openPageId, collapsedPageIds, sidebarWidth) VALUES (?, ?, '[]', 320)
                """, arguments: [WindowState.mainWindowId.uuidString.lowercased(), pageId.uuidString.lowercased()])
        }
        old.close()

        let migrated = try AppDatabase.open(at: folder.databaseURL)
        defer { migrated.close() }
        #expect(try migrated.appliedSchemaVersion() == SchemaMigrations.current.steps.last?.version)
        let state = try #require(try NotesStore(database: migrated, clock: clock).windowState(WindowState.mainWindowId))
        #expect(state.openPageId == pageId)
        #expect(state.sidebarWidth == 320)
        #expect(state.isSidebarCollapsed == false)
    }

    @Test("v4 → v5: записи, надгробия и подключение синхронизации на месте; перед миграцией — копия")
    func migrationAddsSyncBookkeeping() throws {
        let folder = try TemporaryFolder()
        let clock = HybridLogicalClock(deviceId: UUID(), wallClock: AdjustableWallClock().reading)
        let upToV4 = SchemaMigrations(steps: Array(SchemaMigrations.current.steps.prefix { $0.version != "v5" }))
        let erasedId = UUID.timeOrdered()

        let old = try AppDatabase.open(at: folder.databaseURL, migrations: upToV4)
        let page = try NotesStore(database: old, clock: clock).write { try $0.createPage(title: "До v5") }
        try old.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO page_tombstone (pageId, erasedAt) VALUES (?, ?)",
                           arguments: [erasedId.uuidString.lowercased(), clock.now().description])
            try db.execute(sql: "INSERT INTO sync_account (id, serverURL, deviceId, deviceName, lastPulledSeq) VALUES (1, 'https://s', 'd', 'Mac', 7)")
        }
        old.close()

        let migrated = try AppDatabase.open(at: folder.databaseURL)
        defer { migrated.close() }
        let store = NotesStore(database: migrated, clock: clock)
        #expect(try store.pageOutline().map(\.title) == ["До v5"])
        #expect(try store.pageContent(page.id)?.blocks.count == 1)
        #expect(try store.pageTombstones().map(\.pageId) == [erasedId])
        let (known, pulled, sent) = try migrated.dbWriter.read { db in
            (try String.fetchOne(db, sql: "SELECT knownClocks FROM page_tombstone"),
             try Int.fetchOne(db, sql: "SELECT lastPulledSeq FROM sync_account"),
             try Int.fetchOne(db, sql: "SELECT lastSentSeq FROM sync_account"))
        }
        #expect(known == "{}")
        #expect(pulled == 7 && sent == 0)
        #expect(FileManager.default.fileExists(atPath: AppDatabase.backupURL(for: folder.databaseURL, version: "v4").path))
    }

    @Test("Основная база живёт в ~/Library/Application Support/MyNotion/MyNotion.sqlite")
    func defaultLocation() {
        #expect(AppDatabase.defaultURL.path.hasSuffix("Library/Application Support/MyNotion/MyNotion.sqlite"))
    }
}
