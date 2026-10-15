import Foundation
import GRDB

// Перевод записей в строки таблиц и обратно. id хранятся строками UUID в нижнем регистре,
// метки часов — строками HybridTimestamp, наборы меток и оформление — JSON.

extension UUID {
    var databaseText: String { uuidString.lowercased() }
}

enum RowDecoding {
    static func uuid(_ row: Row, _ column: String) throws -> UUID {
        guard let uuid = optionalUUID(row, column) else {
            throw NotesStoreError.corruptedRecord("Колонка \(column) — не UUID")
        }
        return uuid
    }

    static func optionalUUID(_ row: Row, _ column: String) -> UUID? {
        (row[column] as String?).flatMap(UUID.init(uuidString:))
    }

    static func sortKey(_ row: Row) throws -> FractionalSortKey {
        guard let key = FractionalSortKey(rawValue: row["sortKey"]) else {
            throw NotesStoreError.corruptedRecord("Колонка sortKey — не ключ порядка")
        }
        return key
    }

    static func json<T: Decodable>(_ type: T.Type, _ row: Row, _ column: String) throws -> T {
        let text: String = row[column]
        return try JSONDecoder().decode(type, from: Data(text.utf8))
    }
}

enum JSONColumn {
    static func encode(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    /// Набор меток полей: `{"поле":"метка",…}` по алфавиту. Пишется на каждую запись,
    /// поэтому собирается вручную, без JSONEncoder (эталон — 100 000 блоков).
    static func encodeClocks(_ clocks: [(field: String, stamp: HybridTimestamp?)]) -> String {
        let pairs = clocks
            .compactMap { field, stamp in stamp.map { (field, $0) } }
            .sorted { $0.0 < $1.0 }
            .map { "\"\($0.0)\":\"\($0.1.description)\"" }
        return "{" + pairs.joined(separator: ",") + "}"
    }

    static func encodeRuns(_ runs: [StyledRun]) throws -> String {
        runs.isEmpty ? "[]" : try encode(runs)
    }
}

extension PageFieldClocks {
    var databaseJSON: String {
        JSONColumn.encodeClocks([("title", title), ("icon", icon), ("placement", placement), ("trashedAt", trashedAt)])
    }
}

extension BlockFieldClocks {
    var databaseJSON: String {
        JSONColumn.encodeClocks([("kindAndIndent", kindAndIndent), ("text", text), ("isChecked", isChecked),
                                 ("sortKey", sortKey), ("deleted", deleted)])
    }
}

extension Page {
    init(row: Row) throws {
        self.init(
            id: try RowDecoding.uuid(row, "id"),
            title: row["title"],
            icon: row["icon"],
            parentId: RowDecoding.optionalUUID(row, "parentId"),
            sortKey: try RowDecoding.sortKey(row),
            trashedAt: row["trashedAt"],
            createdAt: row["createdAt"],
            updatedAt: row["updatedAt"],
            fieldClocks: try RowDecoding.json(PageFieldClocks.self, row, "fieldClocks")
        )
    }

    func insert(into db: Database) throws {
        try db.cachedStatement(
            sql: """
                INSERT INTO page (id, title, icon, parentId, sortKey, trashedAt, createdAt, updatedAt, fieldClocks)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """
        ).execute(arguments: [id.databaseText, title, icon, parentId?.databaseText, sortKey.rawValue,
                        trashedAt, createdAt, updatedAt, fieldClocks.databaseJSON]
        )
    }

    func update(in db: Database) throws {
        try db.cachedStatement(
            sql: """
                UPDATE page SET title = ?, icon = ?, parentId = ?, sortKey = ?, trashedAt = ?,
                    updatedAt = ?, fieldClocks = ?
                WHERE id = ?
                """
        ).execute(arguments: [title, icon, parentId?.databaseText, sortKey.rawValue, trashedAt,
                        updatedAt, fieldClocks.databaseJSON, id.databaseText]
        )
    }
}

extension Block {
    init(row: Row) throws {
        guard let kind = BlockKind(rawValue: row["kind"]) else {
            throw NotesStoreError.corruptedRecord("Колонка kind — неизвестный тип блока")
        }
        let textBaseClock: String? = row["textBaseClock"]
        self.init(
            id: try RowDecoding.uuid(row, "id"),
            pageId: try RowDecoding.uuid(row, "pageId"),
            kind: kind,
            text: InlineText(row["text"], runs: try RowDecoding.json([StyledRun].self, row, "textStyles")),
            indent: row["indent"],
            isChecked: row["isChecked"],
            linkedPageId: RowDecoding.optionalUUID(row, "linkedPageId"),
            sortKey: try RowDecoding.sortKey(row),
            fieldClocks: try RowDecoding.json(BlockFieldClocks.self, row, "fieldClocks"),
            textBaseClock: textBaseClock.flatMap(HybridTimestamp.init)
        )
    }

    func insert(into db: Database) throws {
        try db.cachedStatement(
            sql: """
                INSERT INTO block (id, pageId, kind, text, textStyles, indent, isChecked, linkedPageId,
                    sortKey, isDeleted, fieldClocks, textBaseClock)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?)
                """
        ).execute(arguments: [id.databaseText, pageId.databaseText, kind.rawValue, text.string,
                        try JSONColumn.encodeRuns(text.runs), indent, isChecked, linkedPageId?.databaseText,
                        sortKey.rawValue, fieldClocks.databaseJSON, textBaseClock?.description]
        )
    }

    func update(in db: Database) throws {
        try db.cachedStatement(
            sql: """
                UPDATE block SET kind = ?, text = ?, textStyles = ?, indent = ?, isChecked = ?, linkedPageId = ?,
                    sortKey = ?, fieldClocks = ?, textBaseClock = ?
                WHERE id = ?
                """
        ).execute(arguments: [kind.rawValue, text.string, try JSONColumn.encodeRuns(text.runs), indent, isChecked,
                        linkedPageId?.databaseText, sortKey.rawValue, fieldClocks.databaseJSON,
                        textBaseClock?.description, id.databaseText]
        )
    }
}

extension Conflict {
    init(row: Row) throws {
        self.init(
            id: try RowDecoding.uuid(row, "id"),
            blockId: try RowDecoding.uuid(row, "blockId"),
            localVersion: try RowDecoding.json(InlineText.self, row, "localVersion"),
            remoteVersion: try RowDecoding.json(InlineText.self, row, "remoteVersion"),
            remoteDeviceName: row["remoteDeviceName"],
            detectedAt: row["detectedAt"],
            resolvedAt: row["resolvedAt"]
        )
    }

    func insert(into db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO conflict (id, blockId, localVersion, remoteVersion, remoteDeviceName, detectedAt, resolvedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [id.databaseText, blockId.databaseText, try JSONColumn.encode(localVersion),
                        try JSONColumn.encode(remoteVersion), remoteDeviceName, detectedAt, resolvedAt]
        )
    }

    func update(in db: Database) throws {
        try db.execute(
            sql: "UPDATE conflict SET localVersion = ?, remoteVersion = ?, remoteDeviceName = ?, resolvedAt = ? WHERE id = ?",
            arguments: [try JSONColumn.encode(localVersion), try JSONColumn.encode(remoteVersion), remoteDeviceName,
                        resolvedAt, id.databaseText]
        )
    }
}

extension WindowState {
    init(row: Row) throws {
        let collapsed = try RowDecoding.json([UUID].self, row, "collapsedPageIds")
        self.init(
            windowId: try RowDecoding.uuid(row, "windowId"),
            openPageId: RowDecoding.optionalUUID(row, "openPageId"),
            collapsedPageIds: Set(collapsed),
            sidebarWidth: row["sidebarWidth"]
        )
    }

    func save(in db: Database) throws {
        let collapsed = collapsedPageIds.map(\.databaseText).sorted()
        try db.execute(
            sql: """
                INSERT INTO window_state (windowId, openPageId, collapsedPageIds, sidebarWidth) VALUES (?, ?, ?, ?)
                ON CONFLICT(windowId) DO UPDATE SET openPageId = excluded.openPageId,
                    collapsedPageIds = excluded.collapsedPageIds, sidebarWidth = excluded.sidebarWidth
                """,
            arguments: [windowId.databaseText, openPageId?.databaseText, try JSONColumn.encode(collapsed), sidebarWidth]
        )
    }
}
