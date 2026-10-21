import Foundation
import GRDB

// Перевод записей баз в строки таблиц v9 и обратно (как `RowMapping.swift` для страниц и блоков).

extension JSONValue {
    static func column(_ text: String?) -> JSONValue? {
        text.flatMap { FastJSON.parse($0) ?? JSONValue(jsonText: $0) }
    }
}

extension DatabaseSchema {
    package init(row: Row) throws {
        self.init(pageId: try RowDecoding.uuid(row, "pageId"), isInline: row["isInline"],
                  defaultTemplateId: RowDecoding.optionalUUID(row, "defaultTemplateId"),
                  fieldClocks: RecordClocks(databaseJSON: row["fieldClocks"]))
    }

    func save(in db: Database) throws {
        try db.cachedStatement(sql: """
            INSERT INTO db_database (pageId, isInline, defaultTemplateId, fieldClocks) VALUES (?, ?, ?, ?)
            ON CONFLICT(pageId) DO UPDATE SET isInline = excluded.isInline, defaultTemplateId = excluded.defaultTemplateId,
                fieldClocks = excluded.fieldClocks
            """).execute(arguments: [pageId.databaseText, isInline, defaultTemplateId?.databaseText, fieldClocks.databaseJSON])
    }
}

extension DatabaseProperty {
    package init(row: Row) throws {
        self.init(id: try RowDecoding.uuid(row, "id"), databaseId: try RowDecoding.uuid(row, "databaseId"), name: row["name"],
                  kind: PropertyKind(rawValue: row["type"]), config: JSONValue.column(row["config"]) ?? .emptyObject,
                  sortKey: try RowDecoding.sortKey(row), deletedAt: row["deletedAt"],
                  fieldClocks: RecordClocks(databaseJSON: row["fieldClocks"]))
    }

    func save(in db: Database) throws {
        try db.cachedStatement(sql: """
            INSERT INTO db_property (id, databaseId, name, type, config, sortKey, deletedAt, fieldClocks) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET name = excluded.name, type = excluded.type, config = excluded.config,
                sortKey = excluded.sortKey, deletedAt = excluded.deletedAt, fieldClocks = excluded.fieldClocks
            """).execute(arguments: [id.databaseText, databaseId.databaseText, name, kind.rawValue, config.jsonText, sortKey.rawValue,
                                     deletedAt, fieldClocks.databaseJSON])
    }
}

extension SelectOption {
    package init(row: Row) throws {
        self.init(id: try RowDecoding.uuid(row, "id"), propertyId: try RowDecoding.uuid(row, "propertyId"), name: row["name"],
                  colorName: row["color"], sortKey: try RowDecoding.sortKey(row),
                  statusGroup: (row["statusGroup"] as String?).flatMap(StatusGroup.init(rawValue:)), deletedAt: row["deletedAt"],
                  fieldClocks: RecordClocks(databaseJSON: row["fieldClocks"]))
    }

    func save(in db: Database) throws {
        try db.cachedStatement(sql: """
            INSERT INTO db_select_option (id, propertyId, name, color, sortKey, statusGroup, deletedAt, fieldClocks)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET name = excluded.name, color = excluded.color, sortKey = excluded.sortKey,
                statusGroup = excluded.statusGroup, deletedAt = excluded.deletedAt, fieldClocks = excluded.fieldClocks
            """).execute(arguments: [id.databaseText, propertyId.databaseText, name, color, sortKey.rawValue, statusGroup?.rawValue,
                                     deletedAt, fieldClocks.databaseJSON])
    }
}

extension CellRecord {
    package init(row: Row) throws {
        guard let hlc = HybridTimestamp(row["hlc"] as String) else { throw NotesStoreError.corruptedRecord("Колонка hlc — не метка часов") }
        self.init(rowId: try RowDecoding.uuid(row, "rowId"), propertyId: try RowDecoding.uuid(row, "propertyId"),
                  value: JSONValue.column(row["value"]), hlc: hlc)
    }

    /// Значение и метка; сравнимые колонки пишет подписчик `CellIndexer` в той же транзакции.
    func save(in db: Database) throws {
        try db.cachedStatement(sql: """
            INSERT INTO db_cell (rowId, propertyId, value, hlc) VALUES (?, ?, ?, ?)
            ON CONFLICT(rowId, propertyId) DO UPDATE SET value = excluded.value, hlc = excluded.hlc
            """).execute(arguments: [rowId.databaseText, propertyId.databaseText, value.map(\.jsonText), hlc.description])
    }
}

extension RelationLink {
    package init(row: Row) throws {
        self.init(propertyId: try RowDecoding.uuid(row, "propertyId"), rowId: try RowDecoding.uuid(row, "rowId"),
                  targetRowId: try RowDecoding.uuid(row, "targetRowId"), sortKey: try RowDecoding.sortKey(row),
                  isPresent: row["isPresent"], fieldClocks: RecordClocks(databaseJSON: row["fieldClocks"]))
    }

    func save(in db: Database) throws {
        try db.cachedStatement(sql: """
            INSERT INTO db_relation_link (id, propertyId, rowId, targetRowId, sortKey, isPresent, fieldClocks) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET sortKey = excluded.sortKey, isPresent = excluded.isPresent, fieldClocks = excluded.fieldClocks
            """).execute(arguments: [id.databaseText, propertyId.databaseText, rowId.databaseText, targetRowId.databaseText,
                                     sortKey.rawValue, isPresent, fieldClocks.databaseJSON])
    }
}

extension DatabaseView {
    package init(row: Row) throws {
        self.init(id: try RowDecoding.uuid(row, "id"), databaseId: try RowDecoding.uuid(row, "databaseId"), name: row["name"],
                  type: row["type"], sortKey: try RowDecoding.sortKey(row), filter: JSONValue.column(row["filter"]),
                  sorts: JSONValue.column(row["sorts"]) ?? [], columns: JSONValue.column(row["columns"]) ?? [],
                  group: JSONValue.column(row["grouping"]), layoutOptions: JSONValue.column(row["layoutOptions"]) ?? .emptyObject,
                  fieldClocks: RecordClocks(databaseJSON: row["fieldClocks"]))
    }

    func save(in db: Database) throws {
        try db.cachedStatement(sql: """
            INSERT INTO db_view (id, databaseId, name, type, sortKey, filter, sorts, columns, grouping, layoutOptions, fieldClocks)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET name = excluded.name, type = excluded.type, sortKey = excluded.sortKey,
                filter = excluded.filter, sorts = excluded.sorts, columns = excluded.columns, grouping = excluded.grouping,
                layoutOptions = excluded.layoutOptions, fieldClocks = excluded.fieldClocks
            """).execute(arguments: [id.databaseText, databaseId.databaseText, name, type, sortKey.rawValue, filter.map(\.jsonText),
                                     sorts.jsonText, columns.jsonText, group.map(\.jsonText), layoutOptions.jsonText,
                                     fieldClocks.databaseJSON])
    }
}

extension RowOrder {
    package init(row: Row) throws {
        guard let hlc = HybridTimestamp(row["hlc"] as String) else { throw NotesStoreError.corruptedRecord("Колонка hlc — не метка часов") }
        self.init(viewId: try RowDecoding.uuid(row, "viewId"), rowId: try RowDecoding.uuid(row, "rowId"),
                  sortKey: try RowDecoding.sortKey(row), hlc: hlc)
    }

    func save(in db: Database) throws {
        try db.cachedStatement(sql: """
            INSERT INTO db_row_order (id, viewId, rowId, sortKey, hlc) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET sortKey = excluded.sortKey, hlc = excluded.hlc
            """).execute(arguments: [id.databaseText, viewId.databaseText, rowId.databaseText, sortKey.rawValue, hlc.description])
    }
}
