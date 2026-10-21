import Foundation

/// Вид базы (data-model.md, `db_view`). Фильтр, сортировки, колонки, группа и настройки — JSON как есть:
/// их смысл знает модуль `Databases`, ядро только хранит.
public struct DatabaseView: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let databaseId: UUID
    public var name: String
    /// `table`; 005 добавит другие — неизвестный тип показывается таблицей.
    public var type: String
    public var sortKey: FractionalSortKey
    public var filter: JSONValue?
    public var sorts: JSONValue
    public var columns: JSONValue
    public var group: JSONValue?
    public var layoutOptions: JSONValue
    public var fieldClocks: RecordClocks<Field>

    public init(id: UUID = .timeOrdered(), databaseId: UUID, name: String = "Таблица", type: String = "table", sortKey: FractionalSortKey,
                filter: JSONValue? = nil, sorts: JSONValue = [], columns: JSONValue = [], group: JSONValue? = nil,
                layoutOptions: JSONValue = .emptyObject, fieldClocks: RecordClocks<Field> = .init()) {
        self.id = id
        self.databaseId = databaseId
        self.name = name
        self.type = type
        self.sortKey = sortKey
        self.filter = filter
        self.sorts = sorts
        self.columns = columns
        self.group = group
        self.layoutOptions = layoutOptions
        self.fieldClocks = fieldClocks
    }

    public enum Field: String, Sendable, Hashable, CaseIterable, Codable {
        case name, type, sortKey, filter, sorts, columns, group, layoutOptions
    }

    public func changedFields(comparedTo old: DatabaseView) -> Set<Field> {
        var fields: Set<Field> = []
        if name != old.name { fields.insert(.name) }
        if type != old.type { fields.insert(.type) }
        if sortKey != old.sortKey { fields.insert(.sortKey) }
        if filter != old.filter { fields.insert(.filter) }
        if sorts != old.sorts { fields.insert(.sorts) }
        if columns != old.columns { fields.insert(.columns) }
        if group != old.group { fields.insert(.group) }
        if layoutOptions != old.layoutOptions { fields.insert(.layoutOptions) }
        return fields
    }
}
