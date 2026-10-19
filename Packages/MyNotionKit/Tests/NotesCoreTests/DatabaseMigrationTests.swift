import Foundation
import GRDB
import Testing
@testable import NotesCore

/// Страница с одним пустым абзацем так, как её записывает 001: в базу старой схемы текущий код писать не может.
private func insertPageAsIn001(_ title: String, into database: AppDatabase) throws -> UUID {
    let pageId = UUID.timeOrdered()
    try database.dbWriter.write { db in
        try db.execute(sql: """
            INSERT INTO page (id, title, sortKey, createdAt, updatedAt, fieldClocks) VALUES (?, ?, 'm', ?, ?, '{}')
            """, arguments: [pageId.uuidString.lowercased(), title, Date(), Date()])
        try db.execute(sql: """
            INSERT INTO block (id, pageId, kind, text, sortKey, fieldClocks) VALUES (?, ?, 'paragraph', '', 'm', '{}')
            """, arguments: [UUID.timeOrdered().uuidString.lowercased(), pageId.uuidString.lowercased()])
    }
    return pageId
}

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
        let pageId = try insertPageAsIn001("Старая запись", into: old)
        old.close()

        let migrated = try AppDatabase.open(at: folder.databaseURL)
        #expect(try migrated.appliedSchemaVersion() == SchemaMigrations.current.steps.last?.version)
        #expect(try NotesStore(database: migrated, clock: clock).pageOutline().map(\.title) == ["Старая запись"])
        #expect(try NotesStore(database: migrated, clock: clock).pageContent(pageId)?.blocks.count == 1)
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
        let pageId = try insertPageAsIn001("До v5", into: old)
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
        #expect(try store.pageContent(pageId)?.blocks.count == 1)
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

@Suite("Миграция v5 → v6")
struct SchemaV6MigrationTests {
    static let upToV5 = SchemaMigrations(steps: Array(SchemaMigrations.current.steps.prefix { $0.version != "v6" }))
    let pageId = UUID.timeOrdered()
    let blockIds = (0..<3).map { _ in UUID.timeOrdered() }
    let conflictId = UUID.timeOrdered()
    let device = UUID()

    /// Эталон v5: страница, три блока с оформлением и метками часов, конфликт, исходящая пачка, индекс поиска —
    /// записаны так, как их пишет 001.
    func makeV5Library(at url: URL) throws {
        let database = try AppDatabase.open(at: url, migrations: Self.upToV5)
        defer { database.close() }
        #expect(try database.appliedSchemaVersion() == "v5")
        let stamp = HybridTimestamp(wallMillis: 1_760_000_000_000, counter: 1, deviceId: device).description
        try database.dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO page (id, title, icon, parentId, sortKey, trashedAt, createdAt, updatedAt, fieldClocks)
                VALUES (?, 'Эталон', '📘', NULL, 'm', NULL, '2026-10-01 10:00:00', '2026-10-01 10:00:00',
                        '{"icon":"\(stamp)","placement":"\(stamp)","title":"\(stamp)","trashedAt":"\(stamp)"}')
                """, arguments: [pageId.databaseText])
            let rows: [(String, String, String, Int, Bool, String)] = [
                ("heading1", "Заголовок", "[]", 0, false, "a"),
                ("bulletItem", "жирный пункт", #"[{"length":6,"start":0,"style":"bold"}]"#, 1, false, "b"),
                ("checkbox", "ссылка", #"[{"length":6,"start":0,"style":"link","url":"https://example.com"}]"#, 0, true, "c"),
            ]
            for (index, row) in rows.enumerated() {
                try db.execute(sql: """
                    INSERT INTO block (id, pageId, kind, text, textStyles, indent, isChecked, linkedPageId, sortKey, isDeleted,
                                       fieldClocks, textBaseClock)
                    VALUES (?, ?, ?, ?, ?, ?, ?, NULL, ?, 0, ?, ?)
                    """, arguments: [blockIds[index].databaseText, pageId.databaseText, row.0, row.1, row.2, row.3, row.4, row.5,
                                     #"{"isChecked":"\#(stamp)","kindAndIndent":"\#(stamp)","sortKey":"\#(stamp)","text":"\#(stamp)"}"#,
                                     stamp])
            }
            try db.execute(sql: """
                INSERT INTO conflict (id, blockId, localVersion, remoteVersion, remoteDeviceName, detectedAt, resolvedAt)
                VALUES (?, ?, '{"runs":[],"string":"моё"}', '{"runs":[],"string":"чужое"}', 'MacBook', '2026-10-02 10:00:00', NULL)
                """, arguments: [conflictId.databaseText, blockIds[0].databaseText])
            try db.execute(sql: "INSERT INTO outbox_entry (id, createdAt, payload) VALUES ('e1', '2026-10-02 10:00:00', ?)",
                           arguments: [Data(#"[{"entity":"block"}]"#.utf8)])
            try db.execute(sql: "INSERT INTO sync_account (id, serverURL, deviceId, deviceName, lastPulledSeq) VALUES (1, 'https://s', 'd', 'Mac', 7)")
            try SchemaMigrations.fillSearchIndex(db)
        }
    }

    /// Всё содержимое базы, кроме служебных таблиц, — для сравнения «ничего не поменялось».
    static func dump(_ database: AppDatabase) throws -> [String] {
        try database.dbWriter.read { db in
            let tables = try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'search_index_%'
                ORDER BY name
                """)
            var lines = try String.fetchAll(db, sql: "SELECT coalesce(sql, '') FROM sqlite_master ORDER BY name")
            for table in tables {
                lines += try Row.fetchAll(db, sql: "SELECT rowid, * FROM \(table) ORDER BY rowid").map { "\(table): \($0)" }
            }
            return lines
        }
    }

    @Test("Эталон v5 → v6: блоки, тексты, оформление, конфликты и очередь исходящих на месте; sortKey стал placement")
    func migratesV5Library() throws {
        let folder = try TemporaryFolder()
        try makeV5Library(at: folder.databaseURL)
        let (rowidsBefore, searchBefore) = try {
            let old = try AppDatabase.open(at: folder.databaseURL, migrations: Self.upToV5)
            defer { old.close() }
            return try old.dbWriter.read { db in
                (try Row.fetchAll(db, sql: "SELECT rowid, id FROM block ORDER BY rowid").map { "\($0["rowid"] as Int64):\($0["id"] as String)" },
                 try Row.fetchAll(db, sql: "SELECT rowid, blockId, content FROM search_index ORDER BY rowid").map(\.description))
            }
        }()

        let database = try AppDatabase.open(at: folder.databaseURL)
        defer { database.close() }
        #expect(try database.appliedSchemaVersion() == "v6")
        let store = NotesStore(database: database, clock: HybridLogicalClock(deviceId: device))
        let blocks = try #require(try store.pageContent(pageId)).blocks
        #expect(blocks.map(\.id) == blockIds)
        #expect(blocks.map(\.kind) == [.heading1, .bulletItem, .checkbox])
        #expect(blocks.map(\.text.string) == ["Заголовок", "жирный пункт", "ссылка"])
        #expect(blocks[1].text.runs == [StyledRun(start: 0, length: 6, style: .bold)])
        #expect(blocks[2].text.runs == [StyledRun(start: 0, length: 6, style: .link(URL(string: "https://example.com")!))])
        #expect(blocks.map(\.indent) == [0, 1, 0])
        #expect(blocks[2].isChecked)
        #expect(blocks.allSatisfy { $0.containerId == nil && $0.color == .none && $0.props == .empty })
        let stamp = HybridTimestamp(wallMillis: 1_760_000_000_000, counter: 1, deviceId: device)
        #expect(blocks.allSatisfy { $0.fieldClocks.placement == stamp && $0.fieldClocks.kindAndIndent == stamp && $0.fieldClocks.text == stamp })
        #expect(try store.unresolvedConflicts(ofPage: pageId).map(\.id) == [conflictId])
        #expect(try outboxCount(database) == 1)

        let (columns, tables, clocks, rowidsAfter, searchAfter, indexes) = try database.dbWriter.read { db in
            (try Row.fetchAll(db, sql: "PRAGMA table_info(block)").map { "\($0["name"] as String) \($0["type"] as String) \($0["notnull"] as Int) \(($0["dflt_value"] as String?) ?? "-")" },
             try String.fetchSet(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"),
             try String.fetchAll(db, sql: "SELECT fieldClocks FROM block"),
             try Row.fetchAll(db, sql: "SELECT rowid, id FROM block ORDER BY rowid").map { "\($0["rowid"] as Int64):\($0["id"] as String)" },
             try Row.fetchAll(db, sql: "SELECT rowid, blockId, content FROM search_index ORDER BY rowid").map(\.description),
             try String.fetchSet(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'block'"))
        }
        #expect(columns.contains("containerId TEXT 0 -"))
        #expect(columns.contains("color TEXT 0 -"))
        #expect(columns.contains("props TEXT 1 '{}'"))
        #expect(Set(["attachment", "reminder_state", "reminder_index", "block_view_state"]).isSubset(of: tables))
        #expect(clocks.allSatisfy { $0.contains("\"placement\"") && !$0.contains("sortKey") })
        #expect(rowidsAfter == rowidsBefore, "rowid блоков — ключ индекса поиска — не меняется")
        #expect(searchAfter == searchBefore)
        #expect(indexes.isSuperset(of: ["block_by_page", "block_deleted", "block_by_container"]))
        let containerIndex = try database.dbWriter.read { db in
            try String.fetchOne(db, sql: "SELECT sql FROM sqlite_master WHERE name = 'block_by_container'")
        }
        #expect(containerIndex?.contains("WHERE containerId IS NOT NULL") == true)
        // Новые типы проходят проверку типа в таблице.
        try store.write { tx in
            let toggle = try tx.insertBlock(Block(pageId: pageId, kind: .toggle, sortKey: .between(blocks[2].sortKey, nil)))
            #expect(toggle.kind == .toggle)
        }
    }

    @Test("Перед v6 — копия MyNotion.backup-v5.sqlite, из неё база восстанавливается целиком")
    func backupAndRestore() throws {
        let folder = try TemporaryFolder()
        try makeV5Library(at: folder.databaseURL)
        let before = try { let db = try AppDatabase.open(at: folder.databaseURL, migrations: Self.upToV5); defer { db.close() }; return try Self.dump(db) }()

        try AppDatabase.open(at: folder.databaseURL).close()
        let backup = AppDatabase.backupURL(for: folder.databaseURL, version: "v5")
        #expect(backup.lastPathComponent == "MyNotion.backup-v5.sqlite")
        #expect(FileManager.default.fileExists(atPath: backup.path))

        try AppDatabase.restore(backup: backup, over: folder.databaseURL)
        let restored = try AppDatabase.open(at: folder.databaseURL, migrations: Self.upToV5)
        defer { restored.close() }
        #expect(try restored.appliedSchemaVersion() == "v5")
        #expect(try Self.dump(restored) == before)
    }

    @Test("Повтор миграции ничего не меняет")
    func secondOpenChangesNothing() throws {
        let folder = try TemporaryFolder()
        try makeV5Library(at: folder.databaseURL)
        let first = try AppDatabase.open(at: folder.databaseURL)
        let afterFirst = try Self.dump(first)
        first.close()
        let second = try AppDatabase.open(at: folder.databaseURL)
        defer { second.close() }
        #expect(try Self.dump(second) == afterFirst)
    }

    @Test("Новая база проходит v1…v6 и принимает все типы блоков")
    func freshDatabaseAcceptsAllKinds() throws {
        let folder = try TemporaryFolder()
        let store = try NotesStore(database: AppDatabase.open(at: folder.databaseURL), clock: HybridLogicalClock(deviceId: device))
        try store.write { tx in
            let page = try tx.createPage(title: "Все типы")
            var key = try tx.blocks(ofPage: page.id)[0].sortKey
            for kind in BlockKind.allCases where kind != .pageLink {
                key = .between(key, nil)
                try tx.insertBlock(Block(pageId: page.id, kind: kind, sortKey: key))
            }
        }
    }

    @Test("База от более новой версии: «База от новой версии MyNotion», запись не идёт")
    func refusesNewerDatabase() throws {
        let folder = try TemporaryFolder()
        try AppDatabase.open(at: folder.databaseURL, migrations: SchemaMigrations.current.appending("v99-future") { db in
            try db.execute(sql: "CREATE TABLE future (id INTEGER)")
        }).close()
        let modified = try FileManager.default.attributesOfItem(atPath: folder.databaseURL.path)[.modificationDate] as? Date

        #expect {
            try AppDatabase.open(at: folder.databaseURL)
        } throws: { error in
            (error as? AppDatabaseError) == .newerVersion && (error as? LocalizedError)?.errorDescription == "База от новой версии MyNotion — обновите приложение"
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.url.path)
        #expect(!files.contains { $0.contains("backup") }, "копия не нужна: запись не идёт")
        #expect(try FileManager.default.attributesOfItem(atPath: folder.databaseURL.path)[.modificationDate] as? Date == modified)
    }
}

private func outboxCount(_ database: AppDatabase) throws -> Int {
    try database.dbWriter.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM outbox_entry") ?? 0 }
}
