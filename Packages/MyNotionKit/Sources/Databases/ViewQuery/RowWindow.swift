import Foundation
import GRDB
import NotesCore

/// Связанная строка в ячейке связи.
public struct RelatedRow: Sendable, Hashable {
    public var id: UUID
    public var title: String
    public var icon: String?
}

/// Всё, что нужно показать строку вида: страница, значения ячеек, итоги формул и сводок, связи.
public struct RowSnapshot: Sendable, Hashable {
    public let id: UUID
    public var title: String
    public var icon: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var cells: [UUID: JSONValue]
    public var computed: [UUID: JSONValue]
    public var relations: [UUID: [RelatedRow]]
}

/// Окно видимых строк (research R3): ячейки читаются только для них, порциями — четыре запроса на порцию.
public enum RowWindowReader {
    public static func read(_ rowIds: [UUID], catalog: DatabaseCatalog, in db: Database) throws -> [UUID: RowSnapshot] {
        guard !rowIds.isEmpty else { return [:] }
        let ids = rowIds.map(\.databaseText)
        let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
        var rows: [UUID: RowSnapshot] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT id, title, icon, createdAt, updatedAt FROM page WHERE id IN (\(marks))",
                                    arguments: StatementArguments(ids)) {
            guard let id = UUID(uuidString: row[0]) else { continue }
            rows[id] = RowSnapshot(id: id, title: row[1], icon: row[2], createdAt: row[3], updatedAt: row[4], cells: [:], computed: [:],
                                   relations: [:])
        }
        for (table, isComputed) in [("db_cell", false), ("db_computed", true)] {
            let cursor = try Row.fetchCursor(db, sql: "SELECT rowId, propertyId, value FROM \(table) WHERE rowId IN (\(marks)) AND value IS NOT NULL",
                                             arguments: StatementArguments(ids))
            while let row = try cursor.next() {
                guard let rowId = UUID(uuidString: row[0]), let propertyId = UUID(uuidString: row[1]), let text: String = row[2],
                      let value = FastJSON.parse(text) else { continue }
                if isComputed { rows[rowId]?.computed[propertyId] = value } else { rows[rowId]?.cells[propertyId] = value }
            }
        }
        for property in catalog.properties where property.kind == .relation {
            let paired = property.config["pairedPropertyId"]?.string.flatMap(UUID.init(uuidString:))
            let reversed = paired.map { $0.uuidString < property.id.uuidString } ?? false
            let (linkProperty, own, other) = reversed ? (paired!, "targetRowId", "rowId") : (property.id, "rowId", "targetRowId")
            let cursor = try Row.fetchCursor(db, sql: """
                SELECT l.\(own), t.id, t.title, t.icon FROM db_relation_link l JOIN page t ON t.id = l.\(other)
                WHERE l.propertyId = ? AND l.\(own) IN (\(marks)) AND l.isPresent = 1 AND t.trashedAt IS NULL
                ORDER BY l.sortKey, l.id
                """, arguments: StatementArguments([linkProperty.databaseText] + ids))
            while let row = try cursor.next() {
                guard let rowId = UUID(uuidString: row[0]), let targetId = UUID(uuidString: row[1]) else { continue }
                rows[rowId]?.relations[property.id, default: []].append(RelatedRow(id: targetId, title: row[2], icon: row[3]))
            }
        }
        return rows
    }
}

extension RowWindowReader {
    /// То же отдельным чтением хранилища (можно с любой очереди).
    public static func read(_ rowIds: [UUID], catalog: DatabaseCatalog, store: NotesStore) throws -> [UUID: RowSnapshot] {
        try store.database.dbWriter.read { db in try read(rowIds, catalog: catalog, in: db) }
    }
}
