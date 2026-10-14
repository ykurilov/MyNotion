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
        try db.execute(
            sql: """
                INSERT INTO page (id, title, icon, parentId, sortKey, trashedAt, createdAt, updatedAt, fieldClocks)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [id.databaseText, title, icon, parentId?.databaseText, sortKey.rawValue,
                        trashedAt, createdAt, updatedAt, try JSONColumn.encode(fieldClocks)]
        )
    }

    func update(in db: Database) throws {
        try db.execute(
            sql: """
                UPDATE page SET title = ?, icon = ?, parentId = ?, sortKey = ?, trashedAt = ?,
                    updatedAt = ?, fieldClocks = ?
                WHERE id = ?
                """,
            arguments: [title, icon, parentId?.databaseText, sortKey.rawValue, trashedAt,
                        updatedAt, try JSONColumn.encode(fieldClocks), id.databaseText]
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
        try db.execute(
            sql: """
                INSERT INTO block (id, pageId, kind, text, textStyles, indent, isChecked, linkedPageId,
                    sortKey, isDeleted, fieldClocks, textBaseClock)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?)
                """,
            arguments: [id.databaseText, pageId.databaseText, kind.rawValue, text.string,
                        try JSONColumn.encode(text.runs), indent, isChecked, linkedPageId?.databaseText,
                        sortKey.rawValue, try JSONColumn.encode(fieldClocks), textBaseClock?.description]
        )
    }

    func update(in db: Database) throws {
        try db.execute(
            sql: """
                UPDATE block SET kind = ?, text = ?, textStyles = ?, indent = ?, isChecked = ?, linkedPageId = ?,
                    sortKey = ?, fieldClocks = ?, textBaseClock = ?
                WHERE id = ?
                """,
            arguments: [kind.rawValue, text.string, try JSONColumn.encode(text.runs), indent, isChecked,
                        linkedPageId?.databaseText, sortKey.rawValue, try JSONColumn.encode(fieldClocks),
                        textBaseClock?.description, id.databaseText]
        )
    }
}
