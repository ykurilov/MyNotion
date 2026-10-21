import Foundation
import GRDB
import NotesCore

/// Значения одного свойства у всех строк базы одним чтением (группы и итоги колонок, US3): по индексу свойства, без
/// окна строк. Выбор, статус, множественный выбор и флажок — из сравнимых колонок, без разбора JSON; название, даты
/// строки, связи, формулы и сводки — откуда их берёт строка (data-model.md, `db_cell`). Пустых значений в словаре нет.
public enum PropertyValues {
    public static func read(_ property: DatabaseProperty, of databaseId: UUID, context: PropertyContext, in db: Database) throws -> [UUID: JSONValue] {
        var values: [UUID: JSONValue] = [:]
        let propertyId = property.id.databaseText
        func each(_ sql: String, _ arguments: StatementArguments, _ body: (Row) -> Void) throws {
            let cursor = try Row.fetchCursor(db, sql: sql, arguments: arguments)
            while let row = try cursor.next() { body(row) }
        }
        switch property.kind {
        case .title:
            try each("SELECT id, title FROM page WHERE parentId = ? AND trashedAt IS NULL AND isTemplate = 0", [databaseId.databaseText]) { row in
                let title: String = row[1]
                if let id = UUID(uuidString: row[0]), !title.isEmpty { values[id] = .string(title) }
            }
        case .createdTime, .lastEditedTime:
            let column = property.kind == .createdTime ? "createdAt" : "updatedAt"
            try each("SELECT id, \(column) FROM page WHERE parentId = ? AND trashedAt IS NULL AND isTemplate = 0", [databaseId.databaseText]) { row in
                if let id = UUID(uuidString: row[0]), let date: Date = row[1] { values[id] = PropertyValue.pageDate(date, in: context) }
            }
        case .select, .status:
            try each("SELECT rowId, sortText FROM db_cell WHERE propertyId = ? AND sortText IS NOT NULL", [propertyId]) { row in
                if let id = UUID(uuidString: row[0]), let option: String = row[1] { values[id] = .string(option) }
            }
        case .multiSelect:
            try each("SELECT rowId, sortText FROM db_cell WHERE propertyId = ? AND sortText IS NOT NULL AND sortText != ''", [propertyId]) { row in
                guard let id = UUID(uuidString: row[0]), let text: String = row[1] else { return }
                values[id] = .array(text.split(separator: " ").map { .string(String($0)) })
            }
        case .checkbox:
            try each("SELECT rowId FROM db_cell WHERE propertyId = ? AND sortNumber = 1", [propertyId]) { row in
                if let id = UUID(uuidString: row[0]) { values[id] = .bool(true) }
            }
        case .formula, .rollup:
            try each("SELECT rowId, value FROM db_computed WHERE propertyId = ? AND value IS NOT NULL", [propertyId]) { row in
                if let id = UUID(uuidString: row[0]), let text: String = row[1], let value = FastJSON.parse(text), value != .null { values[id] = value }
            }
        case .relation:
            let paired = property.config["pairedPropertyId"]?.string.flatMap(UUID.init(uuidString:))
            let reversed = paired.map { $0.uuidString < property.id.uuidString } ?? false
            let (linkProperty, own, other) = reversed ? (paired!, "targetRowId", "rowId") : (property.id, "rowId", "targetRowId")
            var links: [UUID: [JSONValue]] = [:]
            try each("""
                SELECT l.\(own), t.id, t.title FROM db_relation_link l JOIN page t ON t.id = l.\(other)
                WHERE l.propertyId = ? AND l.isPresent = 1 AND t.trashedAt IS NULL ORDER BY l.sortKey, l.id
                """, [linkProperty.databaseText]) { row in
                guard let id = UUID(uuidString: row[0]), let target: String = row[1] else { return }
                links[id, default: []].append(["id": .string(target), "title": .string(row[2] as String? ?? "")])
            }
            for (id, items) in links { values[id] = .array(items) }
        default:
            try each("SELECT rowId, value FROM db_cell WHERE propertyId = ? AND value IS NOT NULL", [propertyId]) { row in
                if let id = UUID(uuidString: row[0]), let text: String = row[1], let value = FastJSON.parse(text), value != .null { values[id] = value }
            }
        }
        return values
    }
}
