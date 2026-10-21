import Foundation
import NotesCore

/// Дерево фильтра вида (data-model.md, `db_view.filter`): `{and|or: [условие | группа]}` или одно условие.
public indirect enum FilterNode: Sendable, Hashable {
    case condition(FilterCondition)
    case and([FilterNode])
    case or([FilterNode])

    public init?(json: JSONValue?) {
        guard let json else { return nil }
        if let items = json["and"]?.array { self = .and(items.compactMap(FilterNode.init(json:))) }
        else if let items = json["or"]?.array { self = .or(items.compactMap(FilterNode.init(json:))) }
        else if let condition = FilterCondition(json: json) { self = .condition(condition) }
        else { return nil }
    }

    public var json: JSONValue {
        switch self {
        case .condition(let condition): condition.json
        case .and(let items): ["and": .array(items.map(\.json))]
        case .or(let items): ["or": .array(items.map(\.json))]
        }
    }
}

/// Условие фильтра: свойство, условие (contracts/property-types.md, «Условия фильтра») и значение.
public struct FilterCondition: Sendable, Hashable {
    public var propertyId: UUID
    public var op: FilterOperator
    public var value: JSONValue

    public init(propertyId: UUID, op: FilterOperator, value: JSONValue = .null) {
        self.propertyId = propertyId
        self.op = op
        self.value = value
    }

    init?(json: JSONValue) {
        guard let id = json["propertyId"]?.string.flatMap(UUID.init(uuidString:)), let op = json["operator"]?.string else { return nil }
        self.init(propertyId: id, op: FilterOperator(rawValue: op), value: json["value"] ?? .null)
    }

    public var json: JSONValue {
        ["propertyId": .string(propertyId.uuidString.lowercased()), "operator": .string(op.rawValue), "value": value]
    }
}

/// Условие фильтра. Не перечисление: условие от новой версии хранится и не применяется.
public struct FilterOperator: RawRepresentable, Sendable, Hashable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    // Текст, выбор, флажок, связь
    public static let `is` = FilterOperator(rawValue: "is")
    public static let isNot = FilterOperator(rawValue: "isNot")
    public static let contains = FilterOperator(rawValue: "contains")
    public static let doesNotContain = FilterOperator(rawValue: "doesNotContain")
    public static let startsWith = FilterOperator(rawValue: "startsWith")
    public static let endsWith = FilterOperator(rawValue: "endsWith")
    public static let isEmpty = FilterOperator(rawValue: "isEmpty")
    public static let isNotEmpty = FilterOperator(rawValue: "isNotEmpty")
    // Число
    public static let equals = FilterOperator(rawValue: "equals")
    public static let notEquals = FilterOperator(rawValue: "notEquals")
    public static let greaterThan = FilterOperator(rawValue: "greaterThan")
    public static let lessThan = FilterOperator(rawValue: "lessThan")
    public static let greaterThanOrEqual = FilterOperator(rawValue: "greaterThanOrEqual")
    public static let lessThanOrEqual = FilterOperator(rawValue: "lessThanOrEqual")
    // Дата
    public static let isBefore = FilterOperator(rawValue: "isBefore")
    public static let isAfter = FilterOperator(rawValue: "isAfter")
    public static let isOnOrBefore = FilterOperator(rawValue: "isOnOrBefore")
    public static let isOnOrAfter = FilterOperator(rawValue: "isOnOrAfter")
    public static let isBetween = FilterOperator(rawValue: "isBetween")
    public static let isRelativeToToday = FilterOperator(rawValue: "isRelativeToToday")
    // Статус
    public static let isInGroup = FilterOperator(rawValue: "isInGroup")
}

/// Сортировка вида (`db_view.sorts`).
public struct SortSpec: Sendable, Hashable {
    public var propertyId: UUID
    public var ascending: Bool

    public init(propertyId: UUID, ascending: Bool = true) {
        self.propertyId = propertyId
        self.ascending = ascending
    }

    public init?(json: JSONValue) {
        guard let id = json["propertyId"]?.string.flatMap(UUID.init(uuidString:)) else { return nil }
        self.init(propertyId: id, ascending: json["direction"]?.string != "descending")
    }
}

/// Что спросить у базы: строки вида после фильтра и поиска, по порядку сортировок, группы, места в виде.
public struct ViewQuerySpec: Sendable, Hashable {
    public var databaseId: UUID
    /// Вид с ручным порядком строк (`db_row_order`); `nil` — порядок создания.
    public var viewId: UUID?
    public var filter: FilterNode?
    public var sorts: [SortSpec]
    /// Свойство группы: ключ группы — первым в порядке.
    public var groupPropertyId: UUID?
    /// Поиск в базе: по названию и видимым свойствам (`searchPropertyIds`).
    public var search: String?
    public var searchPropertyIds: [UUID]

    public init(databaseId: UUID, viewId: UUID? = nil, filter: FilterNode? = nil, sorts: [SortSpec] = [], groupPropertyId: UUID? = nil,
                search: String? = nil, searchPropertyIds: [UUID] = []) {
        self.databaseId = databaseId
        self.viewId = viewId
        self.filter = filter
        self.sorts = sorts
        self.groupPropertyId = groupPropertyId
        self.search = search
        self.searchPropertyIds = searchPropertyIds
    }

    /// Настройки из записи вида.
    public init(view: DatabaseView, search: String? = nil, searchPropertyIds: [UUID] = []) {
        self.init(databaseId: view.databaseId, viewId: view.id, filter: FilterNode(json: view.filter),
                  sorts: view.sorts.array?.compactMap(SortSpec.init(json:)) ?? [],
                  groupPropertyId: view.group?["propertyId"]?.string.flatMap(UUID.init(uuidString:)),
                  search: search, searchPropertyIds: searchPropertyIds)
    }
}
