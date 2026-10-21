import Foundation
import GRDB
import Testing
@testable import NotesCore

/// Миграция v9 (T010, data-model.md, «Миграция v9»): эталон v8 → v9 без потерь, восемь таблиц баз с индексами, блок
/// `database`, копия `MyNotion.backup-v8.sqlite` и восстановление из неё, повтор ничего не меняет, база новее — не трогается.
@Suite("Миграция v8 → v9")
struct DatabaseMigrationV9Tests {
    static let upToV8 = SchemaMigrations(steps: Array(SchemaMigrations.current.steps.prefix { $0.version != "v9" }))
    let pageId = UUID.timeOrdered()
    let childId = UUID.timeOrdered()
    let blockIds = (0..<3).map { _ in UUID.timeOrdered() }
    let device = UUID()

    /// Эталон v8: страница с подстраницей, блоки (в том числе ссылка и картинка), вложение, версия, конфликт, очередь,
    /// индекс поиска — как их пишет 003.
    func makeV8Library(at url: URL) throws {
        let database = try AppDatabase.open(at: url, migrations: Self.upToV8)
        defer { database.close() }
        #expect(try database.appliedSchemaVersion() == "v8")
        let stamp = HybridTimestamp(wallMillis: 1_760_000_000_000, counter: 1, deviceId: device).description
        try database.dbWriter.write { db in
            for (id, title, parent) in [(pageId, "Эталон v8", nil), (childId, "Подстраница", pageId)] as [(UUID, String, UUID?)] {
                try db.execute(sql: """
                    INSERT INTO page (id, title, parentId, sortKey, createdAt, updatedAt, fieldClocks, isFullWidth, favorite)
                    VALUES (?, ?, ?, 'm', '2026-10-01 10:00:00', '2026-10-01 10:00:00', ?, 1, 'a')
                    """, arguments: [id.databaseText, title, parent?.databaseText, #"{"title":"\#(stamp)"}"#])
            }
            let blocks: [(String, String, String?, String)] = [
                ("paragraph", "Текст блока", nil, "{}"),
                ("pageLink", "", childId.databaseText, "{}"),
                ("image", "", nil, #"{"attachment":{"id":"F1"},"caption":"подпись"}"#),
            ]
            for (index, block) in blocks.enumerated() {
                try db.execute(sql: """
                    INSERT INTO block (id, pageId, kind, text, linkedPageId, sortKey, props, fieldClocks, textBaseClock)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [blockIds[index].databaseText, pageId.databaseText, block.0, block.1, block.2, "m" + ["a", "b", "c"][index], block.3,
                                     #"{"text":"\#(stamp)"}"#, stamp])
            }
            try db.execute(sql: "INSERT INTO attachment (id, ref, state) VALUES ('F1', '{}', 'local')")
            try db.execute(sql: """
                INSERT INTO page_version (id, pageId, createdAt, deviceName, snapshot, byteCount) VALUES ('v1', ?, '2026-10-01 11:00:00', 'Mac', X'00', 1)
                """, arguments: [pageId.databaseText])
            try db.execute(sql: """
                INSERT INTO conflict (id, blockId, localVersion, remoteVersion, remoteDeviceName, detectedAt)
                VALUES ('0193a1b2-0000-7000-8000-0000000000c1', ?, '{"runs":[],"string":"моё"}', '{"runs":[],"string":"чужое"}', 'MacBook', '2026-10-02 10:00:00')
                """, arguments: [blockIds[0].databaseText])
            try db.execute(sql: "INSERT INTO outbox_entry (id, createdAt, payload) VALUES ('e1', '2026-10-02 10:00:00', ?)",
                           arguments: [Data(#"[{"entity":"block"}]"#.utf8)])
            try SchemaMigrations.fillSearchIndex(db)
        }
    }

    @Test("Эталон v8 → v9: страницы, блоки, вложения, версии, конфликты, очередь и индекс поиска на месте")
    func migratesV8Library() throws {
        let folder = try TemporaryFolder()
        try makeV8Library(at: folder.databaseURL)
        let before = try { let db = try AppDatabase.open(at: folder.databaseURL, migrations: Self.upToV8); defer { db.close() }
            return try Self.contentDump(db) }()

        let database = try AppDatabase.open(at: folder.databaseURL)
        defer { database.close() }
        #expect(try database.appliedSchemaVersion() == "v9")
        #expect(try Self.contentDump(database) == before, "Содержимое 001–003 не изменилось, rowid блоков те же")
        let store = NotesStore(database: database, clock: HybridLogicalClock(deviceId: device))
        let content = try #require(try store.pageContent(pageId))
        #expect(content.blocks.map(\.kind) == [.paragraph, .pageLink, .image])
        #expect(content.blocks[1].linkedPageId == childId)
        #expect(content.page.isFullWidth && content.page.favorite?.rawValue == "a")
        #expect(try store.unresolvedConflicts(ofPage: pageId).count == 1)
    }

    @Test("Восемь таблиц баз и их индексы — по data-model.md")
    func createsDatabaseTables() throws {
        let folder = try TemporaryFolder()
        let database = try AppDatabase.open(at: folder.databaseURL)
        defer { database.close() }
        let (tables, indexes, withoutRowid) = try database.dbWriter.read { db in
            (Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'db_%'")),
             Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name LIKE 'db_%' AND name NOT LIKE 'sqlite_%'")),
             try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'db_%' AND sql LIKE '%WITHOUT ROWID%' ORDER BY name"))
        }
        #expect(tables == ["db_database", "db_property", "db_select_option", "db_cell", "db_relation_link", "db_view", "db_row_order", "db_computed"])
        for index in ["db_property_by_database", "db_select_option_by_property", "db_cell_by_property_number", "db_cell_by_property_text",
                      "db_relation_link_by_row", "db_relation_link_by_target", "db_view_by_database", "db_row_order_by_view",
                      "db_computed_by_property_number", "db_computed_by_property_text"] {
            #expect(indexes.contains(index), "нет индекса \(index)")
        }
        #expect(withoutRowid == ["db_cell", "db_computed"], "ячейки строки лежат рядом")
    }

    @Test("После v9 блок `database` записывается со ссылкой на страницу-базу, без ссылки — нет")
    func acceptsDatabaseBlock() throws {
        let folder = try TemporaryFolder()
        try makeV8Library(at: folder.databaseURL)
        let store = try NotesStore(database: AppDatabase.open(at: folder.databaseURL), clock: HybridLogicalClock(deviceId: device))
        defer { store.database.close() }
        try store.write { tx in
            try tx.insertBlock(Block(pageId: pageId, kind: .database, linkedPageId: childId, sortKey: FractionalSortKey(rawValue: "z")!))
        }
        #expect(try store.pageContent(pageId)?.blocks.last?.kind == .database)
        #expect(throws: NotesStoreError.self) {
            try store.write { tx in try tx.insertBlock(Block(pageId: pageId, kind: .database, sortKey: FractionalSortKey(rawValue: "zz")!)) }
        }
    }

    @Test("Перед v9 — копия MyNotion.backup-v8.sqlite, из неё база восстанавливается целиком")
    func backupAndRestore() throws {
        let folder = try TemporaryFolder()
        try makeV8Library(at: folder.databaseURL)
        let before = try { let db = try AppDatabase.open(at: folder.databaseURL, migrations: Self.upToV8); defer { db.close() }
            return try SchemaV6MigrationTests.dump(db) }()
        try AppDatabase.open(at: folder.databaseURL).close()
        let backup = AppDatabase.backupURL(for: folder.databaseURL, version: "v8")
        #expect(backup.lastPathComponent == "MyNotion.backup-v8.sqlite")
        #expect(FileManager.default.fileExists(atPath: backup.path))
        try AppDatabase.restore(backup: backup, over: folder.databaseURL)
        let restored = try AppDatabase.open(at: folder.databaseURL, migrations: Self.upToV8)
        defer { restored.close() }
        #expect(try restored.appliedSchemaVersion() == "v8")
        #expect(try SchemaV6MigrationTests.dump(restored) == before)
    }

    @Test("Повтор v9 ничего не меняет")
    func secondOpenChangesNothing() throws {
        let folder = try TemporaryFolder()
        try makeV8Library(at: folder.databaseURL)
        let first = try AppDatabase.open(at: folder.databaseURL)
        let afterFirst = try SchemaV6MigrationTests.dump(first)
        first.close()
        let second = try AppDatabase.open(at: folder.databaseURL)
        defer { second.close() }
        #expect(try SchemaV6MigrationTests.dump(second) == afterFirst)
    }

    @Test("База новее v9 не мигрирует и не пишется")
    func refusesNewerDatabase() throws {
        let folder = try TemporaryFolder()
        try AppDatabase.open(at: folder.databaseURL, migrations: SchemaMigrations.current.appending("v10-future") { db in
            try db.execute(sql: "CREATE TABLE future (id INTEGER)")
        }).close()
        #expect(throws: AppDatabaseError.newerVersion) { try AppDatabase.open(at: folder.databaseURL) }
    }

    /// Строки таблиц 001–003 (без схемы): после миграции те же.
    static func contentDump(_ database: AppDatabase) throws -> [String] {
        try database.dbWriter.read { db in
            var lines: [String] = []
            for table in ["page", "block", "attachment", "page_version", "conflict", "outbox_entry", "search_index"] {
                let columns = table == "block"
                    ? "rowid, id, pageId, kind, text, textStyles, indent, isChecked, linkedPageId, sortKey, containerId, color, props, isDeleted, fieldClocks, textBaseClock"
                    : "rowid, *"
                lines += try Row.fetchAll(db, sql: "SELECT \(columns) FROM \(table) ORDER BY rowid").map { "\(table): \($0)" }
            }
            return lines
        }
    }
}
