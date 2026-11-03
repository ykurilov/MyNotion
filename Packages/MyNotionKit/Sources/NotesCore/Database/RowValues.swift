import Foundation
import GRDB

/// Значения строки базы для истории версий (research R15, data-model.md, «Снимок версии»): ячейки свойств со своими
/// записями и связи, где строка — `rowId`. Списки свойств — какие были в базе на момент чтения: восстановление правит
/// только их, свойства, заведённые позже, не трогает. Схема базы и виды сюда не входят — их отменяет ⌘Z.
public struct RowValues: Sendable, Hashable, Codable {
    public struct Cell: Sendable, Hashable, Codable {
        public var propertyId: UUID
        /// `nil` — пусто.
        public var value: JSONValue?
    }

    public struct Link: Sendable, Hashable, Codable {
        public var propertyId: UUID
        public var targetRowId: UUID
        public var sortKey: FractionalSortKey
    }

    /// По одной на каждое живое свойство с ячейками, по порядку свойств.
    public var cells: [Cell]
    /// Живые свойства-связи базы.
    public var relationPropertyIds: [UUID]
    /// Связи строки по этим свойствам, по порядку.
    public var links: [Link]

    public init(cells: [Cell], relationPropertyIds: [UUID], links: [Link]) {
        self.cells = cells
        self.relationPropertyIds = relationPropertyIds
        self.links = links
    }

    /// Значения строки `rowId`; `nil` — страница не строка базы.
    static func read(_ rowId: UUID, in db: Database) throws -> RowValues? {
        guard let databaseId = try String.fetchOne(db, sql: """
            SELECT d.pageId FROM page p JOIN db_database d ON d.pageId = p.parentId WHERE p.id = ?
            """, arguments: [rowId.databaseText]) else { return nil }
        let properties = try Row.fetchAll(db, sql: "SELECT id, type FROM db_property WHERE databaseId = ? AND deletedAt IS NULL ORDER BY sortKey, id",
                                          arguments: [databaseId]).compactMap { row -> (UUID, PropertyKind)? in
            UUID(uuidString: row[0]).map { ($0, PropertyKind(rawValue: row[1])) }
        }
        var stored: [UUID: JSONValue] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT propertyId, value FROM db_cell WHERE rowId = ?", arguments: [rowId.databaseText]) {
            if let id = UUID(uuidString: row[0]), let value = JSONValue.column(row[1]) { stored[id] = value }
        }
        let relationIds = properties.filter { $0.1 == .relation }.map(\.0)
        var links: [Link] = []
        if !relationIds.isEmpty {
            let marks = Array(repeating: "?", count: relationIds.count).joined(separator: ",")
            links = try Row.fetchAll(db, sql: """
                SELECT propertyId, targetRowId, sortKey FROM db_relation_link
                WHERE rowId = ? AND isPresent = 1 AND propertyId IN (\(marks)) ORDER BY propertyId, sortKey, id
                """, arguments: StatementArguments([rowId.databaseText] + relationIds.map(\.databaseText))).compactMap { row in
                guard let propertyId = UUID(uuidString: row[0]), let target = UUID(uuidString: row[1]),
                      let key = FractionalSortKey(rawValue: row[2]) else { return nil }
                return Link(propertyId: propertyId, targetRowId: target, sortKey: key)
            }
        }
        return RowValues(cells: properties.filter { $0.1.storesCells }.map { Cell(propertyId: $0.0, value: stored[$0.0]) },
                         relationPropertyIds: relationIds, links: links)
    }
}

extension NotesStore {
    /// Значения строки базы для снимка версии; `nil` — страница не строка базы.
    public func rowValues(_ rowId: UUID) throws -> RowValues? {
        try database.dbWriter.read { try RowValues.read(rowId, in: $0) }
    }
}

extension NotesTransaction {
    public func rowValues(_ rowId: UUID) throws -> RowValues? {
        try RowValues.read(rowId, in: database)
    }

    /// Вернуть строке значения `values` (восстановление версии и его отмена): ячейки перечисленных свойств и связи
    /// перечисленных свойств-связей; связи, которых в `values` нет, снимаются, связи на стёртые строки не возвращаются.
    /// Свойства, которых в базе уже нет, пропускаются. Возвращает прежние значения тех же свойств — для ⌘Z.
    @discardableResult
    func applyRowValues(_ values: RowValues, to rowId: UUID) throws -> RowValues {
        var before = RowValues(cells: [], relationPropertyIds: [], links: [])
        for cell in values.cells where try property(cell.propertyId) != nil {
            before.cells.append(RowValues.Cell(propertyId: cell.propertyId, value: try self.cell(rowId: rowId, propertyId: cell.propertyId)?.value))
            try setCell(rowId: rowId, propertyId: cell.propertyId, value: cell.value)
        }
        for propertyId in values.relationPropertyIds where try property(propertyId) != nil {
            before.relationPropertyIds.append(propertyId)
            let current = try relationLinks(propertyId: propertyId, rowId: rowId)
            before.links += current.map { RowValues.Link(propertyId: propertyId, targetRowId: $0.targetRowId, sortKey: $0.sortKey) }
            let wanted = values.links.filter { $0.propertyId == propertyId }
            let wantedTargets = Set(wanted.map(\.targetRowId))
            for link in current where !wantedTargets.contains(link.targetRowId) {
                var removed = link
                removed.isPresent = false
                try saveRelationLink(removed)
            }
            for link in wanted where try page(link.targetRowId) != nil {
                var record = try relationLink(RelationLink.id(propertyId: propertyId, rowId: rowId, targetRowId: link.targetRowId))
                    ?? RelationLink(propertyId: propertyId, rowId: rowId, targetRowId: link.targetRowId, sortKey: link.sortKey)
                record.isPresent = true
                record.sortKey = link.sortKey
                try saveRelationLink(record)
            }
        }
        return before
    }
}
