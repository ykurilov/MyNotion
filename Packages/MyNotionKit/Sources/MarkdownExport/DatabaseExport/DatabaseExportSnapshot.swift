import Databases
import Foundation
import GRDB
import NotesCore

/// База целиком на момент выгрузки — одним чтением: схема, строки и шаблоны, ячейки, связи (у пары — с обеих сторон),
/// итоги формул и сводок, ручной порядок строк.
struct DatabaseExportSnapshot: Sendable {
    let schema: DatabaseSchema
    let title: String
    /// Все свойства по порядку, в том числе удалённые.
    let properties: [DatabaseProperty]
    /// Все варианты, в том числе удалённые.
    let options: [SelectOption]
    let views: [DatabaseView]
    /// Строки по порядку, без корзины и шаблонов.
    let rows: [Page]
    let templates: [Page]
    /// Строка → свойство → значение (пустая запись — `nil`).
    let cells: [UUID: [UUID: JSONValue?]]
    /// Строка → свойство-связь → id строк-целей по порядку.
    let relations: [UUID: [UUID: [UUID]]]
    let computed: [UUID: [UUID: JSONValue]]
    let rowOrders: [RowOrder]
    /// Названия строк-целей связей.
    let targetTitles: [UUID: String]

    var catalog: DatabaseCatalog {
        DatabaseCatalog(databaseId: schema.pageId, properties: properties.filter { $0.deletedAt == nil },
                        options: options.filter { $0.deletedAt == nil })
    }

    /// Колонки CSV и строк свойств: название, затем колонки первого вида (и скрытые), затем остальные свойства.
    var columns: [DatabaseProperty] {
        let live = properties.filter { $0.deletedAt == nil }
        let byId = Dictionary(uniqueKeysWithValues: live.map { ($0.id, $0) })
        var result = live.filter { $0.kind == .title }.prefix(1).map { $0 }
        for column in views.first?.columns.array ?? [] {
            guard let id = column["propertyId"]?.string.flatMap(UUID.init(uuidString:)), let property = byId[id],
                  !result.contains(where: { $0.id == id }) else { continue }
            result.append(property)
        }
        return result + live.filter { property in !result.contains { $0.id == property.id } }
    }

    static func read(_ databaseId: UUID, from store: NotesStore) throws -> DatabaseExportSnapshot? {
        try store.database.dbWriter.read { db in try read(databaseId, in: db) }
    }

    static func read(_ databaseId: UUID, in db: Database) throws -> DatabaseExportSnapshot? {
        let id = databaseId.databaseText
        guard let schema = try Row.fetchOne(db, sql: "SELECT * FROM db_database WHERE pageId = ?", arguments: [id]).map(DatabaseSchema.init(row:)),
              let page = try Row.fetchOne(db, sql: "SELECT * FROM page WHERE id = ?", arguments: [id]).map(Page.init(row:)) else { return nil }
        let properties = try Row.fetchAll(db, sql: "SELECT * FROM db_property WHERE databaseId = ? ORDER BY sortKey, id", arguments: [id])
            .map(DatabaseProperty.init(row:))
        let options = try Row.fetchAll(db, sql: """
            SELECT o.* FROM db_select_option o JOIN db_property p ON p.id = o.propertyId WHERE p.databaseId = ? ORDER BY o.sortKey, o.id
            """, arguments: [id]).map(SelectOption.init(row:))
        let views = try Row.fetchAll(db, sql: "SELECT * FROM db_view WHERE databaseId = ? ORDER BY sortKey, id", arguments: [id])
            .map(DatabaseView.init(row:))
        let pages = try Row.fetchAll(db, sql: "SELECT * FROM page WHERE parentId = ? AND trashedAt IS NULL ORDER BY sortKey, id", arguments: [id])
            .map(Page.init(row:))

        var cells: [UUID: [UUID: JSONValue?]] = [:]
        let cellRows = try Row.fetchCursor(db, sql: """
            SELECT c.rowId, c.propertyId, c.value FROM db_cell c JOIN page p ON p.id = c.rowId WHERE p.parentId = ? AND p.trashedAt IS NULL
            """, arguments: [id])
        while let row = try cellRows.next() {
            guard let rowId = UUID(uuidString: row[0]), let propertyId = UUID(uuidString: row[1]) else { continue }
            let text: String? = row[2]
            cells[rowId, default: [:]][propertyId] = .some(text.flatMap { FastJSON.parse($0) ?? JSONValue(jsonText: $0) })
        }
        var computed: [UUID: [UUID: JSONValue]] = [:]
        let computedRows = try Row.fetchCursor(db, sql: """
            SELECT c.rowId, c.propertyId, c.value FROM db_computed c JOIN page p ON p.id = c.rowId WHERE p.parentId = ? AND c.value IS NOT NULL
            """, arguments: [id])
        while let row = try computedRows.next() {
            guard let rowId = UUID(uuidString: row[0]), let propertyId = UUID(uuidString: row[1]), let text: String = row[2],
                  let value = FastJSON.parse(text) ?? JSONValue(jsonText: text) else { continue }
            computed[rowId, default: [:]][propertyId] = value
        }

        // Связи: свои записи свойства и ответные записи пары (data-model.md: пара хранит связь у одной стороны).
        var relations: [UUID: [UUID: [UUID]]] = [:]
        var targets: Set<UUID> = []
        for property in properties where property.kind == .relation {
            var queries = [("""
                SELECT l.rowId, l.targetRowId FROM db_relation_link l JOIN page p ON p.id = l.rowId JOIN page t ON t.id = l.targetRowId
                WHERE l.propertyId = ? AND l.isPresent = 1 AND p.parentId = ? AND t.trashedAt IS NULL ORDER BY l.sortKey, l.id
                """, property.id)]
            if let paired = property.config["pairedPropertyId"]?.string.flatMap(UUID.init(uuidString:)), paired != property.id {
                queries.append(("""
                    SELECT l.targetRowId, l.rowId FROM db_relation_link l JOIN page p ON p.id = l.targetRowId JOIN page t ON t.id = l.rowId
                    WHERE l.propertyId = ? AND l.isPresent = 1 AND p.parentId = ? AND t.trashedAt IS NULL ORDER BY l.sortKey, l.id
                    """, paired))
            }
            for (sql, propertyId) in queries {
                for row in try Row.fetchAll(db, sql: sql, arguments: [propertyId.databaseText, id]) {
                    guard let rowId = UUID(uuidString: row[0]), let target = UUID(uuidString: row[1]) else { continue }
                    if relations[rowId]?[property.id]?.contains(target) == true { continue }
                    relations[rowId, default: [:]][property.id, default: []].append(target)
                    targets.insert(target)
                }
            }
        }
        var targetTitles: [UUID: String] = [:]
        for chunk in Array(targets).chunked(500) {
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            for row in try Row.fetchAll(db, sql: "SELECT id, title FROM page WHERE id IN (\(marks))", arguments: StatementArguments(chunk.map(\.databaseText))) {
                if let target = UUID(uuidString: row[0]) { targetTitles[target] = row[1] }
            }
        }
        let rowOrders = try Row.fetchAll(db, sql: """
            SELECT o.* FROM db_row_order o JOIN db_view v ON v.id = o.viewId WHERE v.databaseId = ? ORDER BY o.id
            """, arguments: [id]).map(RowOrder.init(row:))
        return DatabaseExportSnapshot(schema: schema, title: page.title, properties: properties, options: options, views: views,
                                      rows: pages.filter { !$0.isTemplate }, templates: pages.filter(\.isTemplate), cells: cells,
                                      relations: relations, computed: computed, rowOrders: rowOrders, targetTitles: targetTitles)
    }
}

extension Array {
    func chunked(_ size: Int) -> [ArraySlice<Element>] {
        stride(from: 0, to: count, by: size).map { self[$0..<Swift.min($0 + size, count)] }
    }
}
