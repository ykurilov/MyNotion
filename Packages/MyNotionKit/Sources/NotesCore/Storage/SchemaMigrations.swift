import GRDB

/// Упорядоченный список миграций схемы. Каждая — один шаг версии; уже выпущенные шаги не меняются.
public struct SchemaMigrations: Sendable {
    struct Step: Sendable {
        let version: String
        let migrate: @Sendable (Database) throws -> Void
    }

    let steps: [Step]

    /// Схема текущей версии приложения.
    public static let current = SchemaMigrations(steps: [
        Step(version: "v1", migrate: createInitialSchema),
        Step(version: "v2", migrate: addPageTombstones),
        Step(version: "v3", migrate: addSidebarCollapsed),
        Step(version: "v4", migrate: fillSearchIndex),
    ])

    /// Та же схема плюс ещё один шаг — для проверки миграций.
    package func appending(_ version: String, migrate: @escaping @Sendable (Database) throws -> Void) -> SchemaMigrations {
        SchemaMigrations(steps: steps + [Step(version: version, migrate: migrate)])
    }

    var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        for step in steps {
            migrator.registerMigration(step.version, migrate: step.migrate)
        }
        return migrator
    }
}

private func createInitialSchema(_ db: Database) throws {
    let blockKinds = BlockKind.allCases.map { "'\($0.rawValue)'" }.joined(separator: ", ")

    // id — строки UUID в нижнем регистре, метки часов — строки HybridTimestamp, *Clocks — JSON.
    // У parentId нет внешнего ключа: страница, чей родитель исчез, показывается в корне.
    try db.execute(sql: """
        CREATE TABLE page (
            id TEXT PRIMARY KEY NOT NULL,
            title TEXT NOT NULL,
            icon TEXT,
            parentId TEXT,
            sortKey TEXT NOT NULL,
            trashedAt DATETIME,
            createdAt DATETIME NOT NULL,
            updatedAt DATETIME NOT NULL,
            fieldClocks TEXT NOT NULL
        );
        CREATE INDEX page_by_parent ON page(parentId, sortKey);

        CREATE TABLE block (
            id TEXT PRIMARY KEY NOT NULL,
            pageId TEXT NOT NULL REFERENCES page(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
            kind TEXT NOT NULL CHECK (kind IN (\(blockKinds))),
            text TEXT NOT NULL,
            textStyles TEXT NOT NULL DEFAULT '[]',
            indent INTEGER NOT NULL DEFAULT 0 CHECK (indent BETWEEN 0 AND 8),
            isChecked BOOLEAN NOT NULL DEFAULT 0,
            linkedPageId TEXT,
            sortKey TEXT NOT NULL,
            isDeleted BOOLEAN NOT NULL DEFAULT 0,
            fieldClocks TEXT NOT NULL,
            textBaseClock TEXT
        );
        CREATE INDEX block_by_page ON block(pageId, sortKey);

        CREATE TABLE conflict (
            id TEXT PRIMARY KEY NOT NULL,
            blockId TEXT NOT NULL REFERENCES block(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
            localVersion TEXT NOT NULL,
            remoteVersion TEXT NOT NULL,
            remoteDeviceName TEXT NOT NULL,
            detectedAt DATETIME NOT NULL,
            resolvedAt DATETIME
        );
        CREATE INDEX conflict_by_block ON conflict(blockId);

        CREATE TABLE window_state (
            windowId TEXT PRIMARY KEY NOT NULL,
            openPageId TEXT,
            collapsedPageIds TEXT NOT NULL DEFAULT '[]',
            sidebarWidth DOUBLE NOT NULL DEFAULT 270
        );

        CREATE TABLE import_run (
            id TEXT PRIMARY KEY NOT NULL,
            sourceFingerprint TEXT NOT NULL,
            startedAt DATETIME NOT NULL,
            finishedAt DATETIME,
            rootPageId TEXT,
            importedPages INTEGER NOT NULL DEFAULT 0,
            simplifiedItems TEXT NOT NULL DEFAULT '[]',
            status TEXT NOT NULL CHECK (status IN ('running', 'finished', 'failed'))
        );
        CREATE INDEX import_run_by_fingerprint ON import_run(sourceFingerprint);

        CREATE TABLE sync_account (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            serverURL TEXT NOT NULL,
            deviceId TEXT NOT NULL,
            deviceName TEXT NOT NULL,
            lastPulledSeq INTEGER NOT NULL DEFAULT 0
        );

        CREATE TABLE outbox_entry (
            id TEXT PRIMARY KEY NOT NULL,
            createdAt DATETIME NOT NULL,
            payload BLOB NOT NULL,
            sentAt DATETIME
        );

        CREATE VIRTUAL TABLE search_index USING fts5(
            pageId UNINDEXED,
            blockId UNINDEXED,
            content,
            tokenize = 'unicode61 remove_diacritics 2'
        );
        """)
}

/// Надгробия стёртых навсегда страниц (data-model.md): id и метка часов стирания — для синхронизации.
private func addPageTombstones(_ db: Database) throws {
    try db.execute(sql: """
        CREATE TABLE page_tombstone (
            pageId TEXT PRIMARY KEY NOT NULL,
            erasedAt TEXT NOT NULL
        );
        """)
}

private func addSidebarCollapsed(_ db: Database) throws {
    try db.execute(sql: "ALTER TABLE window_state ADD COLUMN isSidebarCollapsed BOOLEAN NOT NULL DEFAULT 0")
}

extension SchemaMigrations {
    /// Наполнить `search_index` по уже записанным страницам (v4): до US4 таблица создавалась, но не наполнялась.
    /// Строки — те же, что пишет подписчик `SearchIndexer` модуля поиска: название страницы — rowid `-page.rowid`
    /// без blockId, текст блока — rowid `block.rowid`; пустые не индексируются; «ё» записана как «е».
    package static func fillSearchIndex(_ db: Database) throws {
        let content = { (column: String) in "replace(replace(\(column), 'ё', 'е'), 'Ё', 'Е')" }
        try db.execute(sql: """
            DELETE FROM search_index;
            INSERT INTO search_index (rowid, pageId, blockId, content)
                SELECT -rowid, id, NULL, \(content("title")) FROM page WHERE title != '';
            INSERT INTO search_index (rowid, pageId, blockId, content)
                SELECT rowid, pageId, id, \(content("text")) FROM block WHERE isDeleted = 0 AND text != '';
            """)
    }
}
