import Foundation
import GRDB
import NotesCore

/// Схема базы для чтения: свойства и варианты по id (одно чтение на открытие вида).
public struct DatabaseCatalog: Sendable {
    public let databaseId: UUID
    /// Неудалённые свойства по порядку.
    public let properties: [DatabaseProperty]
    public let propertiesById: [UUID: DatabaseProperty]
    /// Неудалённые варианты свойства по порядку (у статуса — по группам, затем по порядку).
    public let options: [UUID: [SelectOption]]
    public let optionsById: [UUID: SelectOption]

    public init(databaseId: UUID, properties: [DatabaseProperty], options: [SelectOption]) {
        self.databaseId = databaseId
        self.properties = properties
        propertiesById = Dictionary(uniqueKeysWithValues: properties.map { ($0.id, $0) })
        var byProperty: [UUID: [SelectOption]] = [:]
        for option in options { byProperty[option.propertyId, default: []].append(option) }
        for (id, list) in byProperty { byProperty[id] = list.sorted(by: Self.optionOrder) }
        self.options = byProperty
        optionsById = Dictionary(uniqueKeysWithValues: options.map { ($0.id, $0) })
    }

    /// Порядок вариантов: у статуса сначала группа («К выполнению», «В работе», «Завершено»), затем место.
    static func optionOrder(_ lhs: SelectOption, _ rhs: SelectOption) -> Bool {
        let left = lhs.statusGroup.flatMap { StatusGroup.allCases.firstIndex(of: $0) } ?? 0
        let right = rhs.statusGroup.flatMap { StatusGroup.allCases.firstIndex(of: $0) } ?? 0
        if left != right { return left < right }
        return lhs.sortKey != rhs.sortKey ? lhs.sortKey < rhs.sortKey : lhs.id.uuidString < rhs.id.uuidString
    }

    public var titleProperty: DatabaseProperty? { properties.first { $0.kind == .title } }

    /// Место варианта в списке его свойства: сравнимое число выбора и статуса (data-model.md, `sortNumber`).
    public func position(ofOption id: UUID) -> Int? {
        guard let option = optionsById[id] else { return nil }
        return options[option.propertyId]?.firstIndex { $0.id == id }
    }

    public static func read(_ databaseId: UUID, in db: Database) throws -> DatabaseCatalog {
        let properties = try Row.fetchAll(db, sql: "SELECT * FROM db_property WHERE databaseId = ? AND deletedAt IS NULL ORDER BY sortKey, id",
                                          arguments: [databaseId.uuidString.lowercased()])
        let decoded = try properties.map(DatabaseProperty.init(row:))
        let options = try Row.fetchAll(db, sql: """
            SELECT o.* FROM db_select_option o JOIN db_property p ON p.id = o.propertyId
            WHERE p.databaseId = ? AND o.deletedAt IS NULL
            """, arguments: [databaseId.uuidString.lowercased()]).map(SelectOption.init(row:))
        return DatabaseCatalog(databaseId: databaseId, properties: decoded, options: options)
    }

    public static func read(_ databaseId: UUID, in store: NotesStore) throws -> DatabaseCatalog {
        try store.database.dbWriter.read { try read(databaseId, in: $0) }
    }
}
