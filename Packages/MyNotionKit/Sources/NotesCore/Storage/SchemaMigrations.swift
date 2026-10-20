import Foundation
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
        Step(version: "v5", migrate: addSyncBookkeeping),
        Step(version: "v6", migrate: addRichBlocks),
        Step(version: "v7", migrate: addPagesNavigation),
        Step(version: "v8", migrate: indexVersionFilesAndMoves),
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

/// Типы блоков первой версии схемы. Выпущенный шаг не меняется: новые типы добавляет v6.
private let blockKindsOf001 = ["paragraph", "heading1", "heading2", "heading3", "bulletItem", "numberedItem", "checkbox", "pageLink"]

private func createInitialSchema(_ db: Database) throws {
    let blockKinds = blockKindsOf001.map { "'\($0)'" }.joined(separator: ", ")

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

/// Синхронизация (v5): в надгробии — какие правки страницы видел стёрший Mac (research R8);
/// в подключении — номер последней своей отправленной пачки и последнего снимка.
private func addSyncBookkeeping(_ db: Database) throws {
    try db.execute(sql: """
        ALTER TABLE page_tombstone ADD COLUMN knownClocks TEXT NOT NULL DEFAULT '{}';
        ALTER TABLE sync_account ADD COLUMN lastSentSeq INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE sync_account ADD COLUMN lastSnapshotSeq INTEGER NOT NULL DEFAULT 0;
        CREATE INDEX block_deleted ON block(isDeleted) WHERE isDeleted = 1;
        """)
}

/// Новые блоки и оформление (002, data-model.md, «Схема v6»). `CHECK` на тип блока в SQLite не поменять — таблица
/// пересоздаётся с теми же rowid (на них держится индекс поиска); в метках полей `sortKey` становится `placement`.
/// GRDB на время миграции выключает внешние ключи и проверяет их в конце: конфликты блоков не стираются.
private func addRichBlocks(_ db: Database) throws {
    let blockKinds = BlockKind.allCases.map { "'\($0.rawValue)'" }.joined(separator: ", ")
    try db.execute(sql: """
        CREATE TABLE block_v6 (
            id TEXT PRIMARY KEY NOT NULL,
            pageId TEXT NOT NULL REFERENCES page(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
            kind TEXT NOT NULL CHECK (kind IN (\(blockKinds))),
            text TEXT NOT NULL,
            textStyles TEXT NOT NULL DEFAULT '[]',
            indent INTEGER NOT NULL DEFAULT 0 CHECK (indent BETWEEN 0 AND 8),
            isChecked BOOLEAN NOT NULL DEFAULT 0,
            linkedPageId TEXT,
            sortKey TEXT NOT NULL,
            containerId TEXT,
            color TEXT,
            props TEXT NOT NULL DEFAULT '{}',
            isDeleted BOOLEAN NOT NULL DEFAULT 0,
            fieldClocks TEXT NOT NULL,
            textBaseClock TEXT
        );
        INSERT INTO block_v6 (rowid, id, pageId, kind, text, textStyles, indent, isChecked, linkedPageId, sortKey,
                              isDeleted, fieldClocks, textBaseClock)
            SELECT rowid, id, pageId, kind, text, textStyles, indent, isChecked, linkedPageId, sortKey,
                   isDeleted, replace(fieldClocks, '"sortKey":', '"placement":'), textBaseClock
            FROM block;
        DROP TABLE block;
        ALTER TABLE block_v6 RENAME TO block;
        CREATE INDEX block_by_page ON block(pageId, sortKey);
        CREATE INDEX block_deleted ON block(isDeleted) WHERE isDeleted = 1;
        CREATE INDEX block_by_container ON block(containerId, sortKey) WHERE containerId IS NOT NULL;

        CREATE TABLE attachment (
            id TEXT PRIMARY KEY NOT NULL,
            ref TEXT NOT NULL,
            localPath TEXT,
            state TEXT NOT NULL CHECK (state IN ('local', 'uploading', 'uploaded', 'remote', 'downloading', 'failed')),
            uploadedParts TEXT NOT NULL DEFAULT '[]',
            downloadedParts TEXT NOT NULL DEFAULT '[]',
            orphanedAt DATETIME,
            lastError TEXT
        );

        CREATE TABLE reminder_state (
            mentionId TEXT PRIMARY KEY NOT NULL,
            doneAt DATETIME,
            doneClock TEXT NOT NULL
        );

        CREATE TABLE reminder_index (
            mentionId TEXT PRIMARY KEY NOT NULL,
            pageId TEXT NOT NULL,
            blockId TEXT NOT NULL,
            fireAt DATETIME NOT NULL,
            deliveredAt DATETIME
        );
        CREATE INDEX reminder_index_by_fire ON reminder_index(fireAt);
        CREATE INDEX reminder_index_by_block ON reminder_index(blockId);

        CREATE TABLE block_view_state (
            blockId TEXT PRIMARY KEY NOT NULL,
            isCollapsed BOOLEAN NOT NULL DEFAULT 0
        );
        """)
}

/// Страницы и навигация (003, data-model.md, «Миграция v7»): поля страницы, локальные таблицы обратных ссылок, версий и
/// отметок, вкладки окна. Только схема: индекс обратных ссылок заполняется позже, в фоне (research R10). Новые метки полей
/// в `fieldClocks` пусты — их просто нет в JSON.
private func addPagesNavigation(_ db: Database) throws {
    try db.execute(sql: """
        ALTER TABLE page ADD COLUMN cover TEXT;
        ALTER TABLE page ADD COLUMN isFullWidth BOOLEAN NOT NULL DEFAULT 0;
        ALTER TABLE page ADD COLUMN isSmallText BOOLEAN NOT NULL DEFAULT 0;
        ALTER TABLE page ADD COLUMN isTemplate BOOLEAN NOT NULL DEFAULT 0;
        ALTER TABLE page ADD COLUMN favorite TEXT;
        ALTER TABLE page ADD COLUMN visitedAt DATETIME;
        CREATE INDEX page_by_favorite ON page(favorite) WHERE favorite IS NOT NULL;
        CREATE INDEX page_by_visit ON page(visitedAt) WHERE visitedAt IS NOT NULL;

        CREATE TABLE page_link (
            sourceBlockId TEXT NOT NULL,
            sourcePageId TEXT NOT NULL,
            targetPageId TEXT NOT NULL,
            PRIMARY KEY (sourceBlockId, targetPageId)
        );
        CREATE INDEX page_link_by_target ON page_link(targetPageId);

        CREATE TABLE page_version (
            id TEXT PRIMARY KEY NOT NULL,
            pageId TEXT NOT NULL,
            createdAt DATETIME NOT NULL,
            deviceName TEXT NOT NULL,
            snapshot BLOB NOT NULL,
            summary TEXT NOT NULL DEFAULT '{}',
            byteCount INTEGER NOT NULL
        );
        CREATE INDEX page_version_by_page ON page_version(pageId, createdAt);

        CREATE TABLE page_version_due (
            pageId TEXT PRIMARY KEY NOT NULL,
            lastChangeAt DATETIME NOT NULL,
            deviceName TEXT NOT NULL
        );

        CREATE TABLE app_meta (
            key TEXT PRIMARY KEY NOT NULL,
            value TEXT NOT NULL
        );

        ALTER TABLE window_state ADD COLUMN tabs TEXT;
        ALTER TABLE window_state ADD COLUMN collapsedSidebarSections TEXT NOT NULL DEFAULT '[]';
        """)
}

/// v8. `page_version_file` — файлы, на которые ссылаются хранимые версии: сборщик сирот их не стирает, пока жива версия
/// (восстановление вернёт блок с файлом). Записи для уже сохранённых версий — по снимкам: файл версии — тот, чей id есть
/// в её снимке. `block.movedFrom` — пометка «Переместить в» из `props`, с индексом: восстановление версии ищет копии
/// своих блоков по id, без полного прохода по блокам. `page_version.isBeforeRestore` — снимок «до восстановления»:
/// прореживание не отдаёт его версии «после» того же часа или дня.
private func indexVersionFilesAndMoves(_ db: Database) throws {
    try db.execute(sql: """
        CREATE TABLE page_version_file (
            versionId TEXT NOT NULL,
            fileId TEXT NOT NULL,
            PRIMARY KEY (versionId, fileId)
        );
        CREATE INDEX page_version_file_by_file ON page_version_file(fileId);
        ALTER TABLE page_version ADD COLUMN isBeforeRestore BOOLEAN NOT NULL DEFAULT 0;

        ALTER TABLE block ADD COLUMN movedFrom TEXT
            GENERATED ALWAYS AS (CASE WHEN json_valid(props) THEN json_extract(props, '$.movedFrom') END) VIRTUAL;
        CREATE INDEX block_by_moved_from ON block(movedFrom) WHERE movedFrom IS NOT NULL;
        """)
    let fileIds = try String.fetchAll(db, sql: "SELECT id FROM attachment")
    guard !fileIds.isEmpty else { return }
    for row in try Row.fetchAll(db, sql: "SELECT id, snapshot FROM page_version") {
        let data: Data = row["snapshot"]
        guard let json = try? (data as NSData).decompressed(using: .lzfse) as Data else { continue }
        let text = String(decoding: json, as: UTF8.self).uppercased()
        for fileId in fileIds where text.contains(fileId.uppercased()) {
            try db.execute(sql: "INSERT OR IGNORE INTO page_version_file (versionId, fileId) VALUES (?, ?)",
                           arguments: [row["id"] as String, fileId])
        }
    }
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
