import Foundation

/// База (data-model.md, `db_database`): страница с этой записью — база; строки — её страницы-дети.
public struct DatabaseSchema: Sendable, Hashable, Identifiable {
    /// Страница-база.
    public let pageId: UUID
    /// Встроенная: в потоке хозяина её показывает блок `database`.
    public var isInline: Bool
    /// Шаблон новой строки; пусто — пустая строка.
    public var defaultTemplateId: UUID?
    public var fieldClocks: RecordClocks<Field>

    public var id: UUID { pageId }

    public init(pageId: UUID, isInline: Bool = false, defaultTemplateId: UUID? = nil, fieldClocks: RecordClocks<Field> = .init()) {
        self.pageId = pageId
        self.isInline = isInline
        self.defaultTemplateId = defaultTemplateId
        self.fieldClocks = fieldClocks
    }

    public enum Field: String, Sendable, Hashable, CaseIterable, Codable {
        case isInline
        case defaultTemplateId
    }

    public func changedFields(comparedTo old: DatabaseSchema) -> Set<Field> {
        var fields: Set<Field> = []
        if isInline != old.isInline { fields.insert(.isInline) }
        if defaultTemplateId != old.defaultTemplateId { fields.insert(.defaultTemplateId) }
        return fields
    }
}

/// Тип свойства (data-model.md, `db_property.type`). Не перечисление: тип от более новой версии хранится как есть.
public struct PropertyKind: RawRepresentable, Sendable, Hashable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    public static let title = PropertyKind(rawValue: "title")
    public static let text = PropertyKind(rawValue: "text")
    public static let number = PropertyKind(rawValue: "number")
    public static let select = PropertyKind(rawValue: "select")
    public static let multiSelect = PropertyKind(rawValue: "multiSelect")
    public static let status = PropertyKind(rawValue: "status")
    public static let date = PropertyKind(rawValue: "date")
    public static let checkbox = PropertyKind(rawValue: "checkbox")
    public static let url = PropertyKind(rawValue: "url")
    public static let email = PropertyKind(rawValue: "email")
    public static let phone = PropertyKind(rawValue: "phone")
    public static let files = PropertyKind(rawValue: "files")
    public static let createdTime = PropertyKind(rawValue: "createdTime")
    public static let lastEditedTime = PropertyKind(rawValue: "lastEditedTime")
    public static let relation = PropertyKind(rawValue: "relation")
    public static let rollup = PropertyKind(rawValue: "rollup")
    public static let formula = PropertyKind(rawValue: "formula")
    public static let uniqueId = PropertyKind(rawValue: "uniqueId")

    /// Все 18 типов 004.
    public static let all: [PropertyKind] = [
        .title, .text, .number, .select, .multiSelect, .status, .date, .checkbox, .url, .email, .phone, .files,
        .createdTime, .lastEditedTime, .relation, .rollup, .formula, .uniqueId,
    ]

    /// У типа есть запись `db_cell` (data-model.md: название — `Page.title`, время — из страницы, связь — `db_relation_link`,
    /// сводка и формула — `db_computed`).
    public var storesCells: Bool {
        ![.title, .createdTime, .lastEditedTime, .relation, .rollup, .formula].contains(self)
    }
}

/// Свойство базы (data-model.md, `db_property`).
public struct DatabaseProperty: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let databaseId: UUID
    public var name: String
    public var kind: PropertyKind
    /// Настройки типа; неизвестные ключи сохраняются.
    public var config: JSONValue
    public var sortKey: FractionalSortKey
    /// Не пусто — в «Удалённых свойствах», значения хранятся.
    public var deletedAt: Date?
    public var fieldClocks: RecordClocks<Field>

    public init(id: UUID = .timeOrdered(), databaseId: UUID, name: String, kind: PropertyKind, config: JSONValue = .emptyObject,
                sortKey: FractionalSortKey, deletedAt: Date? = nil, fieldClocks: RecordClocks<Field> = .init()) {
        self.id = id
        self.databaseId = databaseId
        self.name = name
        self.kind = kind
        self.config = config
        self.sortKey = sortKey
        self.deletedAt = deletedAt
        self.fieldClocks = fieldClocks
    }

    public enum Field: String, Sendable, Hashable, CaseIterable, Codable {
        case name
        /// Тип и настройки — одно поле: смена типа не рвётся на два.
        case typeAndConfig
        case sortKey
        case deletedAt
    }

    public func changedFields(comparedTo old: DatabaseProperty) -> Set<Field> {
        var fields: Set<Field> = []
        if name != old.name { fields.insert(.name) }
        if kind != old.kind || config != old.config { fields.insert(.typeAndConfig) }
        if sortKey != old.sortKey { fields.insert(.sortKey) }
        if deletedAt != old.deletedAt { fields.insert(.deletedAt) }
        return fields
    }
}

/// 10 цветов Notion для вариантов (data-model.md, `db_select_option.color`).
public enum OptionColor: String, Sendable, Hashable, CaseIterable, Codable {
    case `default`, gray, brown, orange, yellow, green, blue, purple, pink, red
}

/// Группа статуса (data-model.md, `statusGroup`), порядок постоянный.
public enum StatusGroup: String, Sendable, Hashable, CaseIterable, Codable {
    case todo, inProgress, complete
}

/// Вариант выбора, множественного выбора и статуса (data-model.md, `db_select_option`).
public struct SelectOption: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let propertyId: UUID
    public var name: String
    /// Цвет Notion; неизвестный цвет от новой версии хранится как есть и показывается `default`.
    public var color: String
    public var sortKey: FractionalSortKey
    public var statusGroup: StatusGroup?
    public var deletedAt: Date?
    public var fieldClocks: RecordClocks<Field>

    public init(id: UUID = .timeOrdered(), propertyId: UUID, name: String, color: OptionColor = .default, sortKey: FractionalSortKey,
                statusGroup: StatusGroup? = nil, deletedAt: Date? = nil, fieldClocks: RecordClocks<Field> = .init()) {
        self.init(id: id, propertyId: propertyId, name: name, colorName: color.rawValue, sortKey: sortKey, statusGroup: statusGroup,
                  deletedAt: deletedAt, fieldClocks: fieldClocks)
    }

    public init(id: UUID, propertyId: UUID, name: String, colorName: String, sortKey: FractionalSortKey, statusGroup: StatusGroup?,
                deletedAt: Date?, fieldClocks: RecordClocks<Field>) {
        self.id = id
        self.propertyId = propertyId
        self.name = name
        self.color = colorName
        self.sortKey = sortKey
        self.statusGroup = statusGroup
        self.deletedAt = deletedAt
        self.fieldClocks = fieldClocks
    }

    public var optionColor: OptionColor { OptionColor(rawValue: color) ?? .default }

    public enum Field: String, Sendable, Hashable, CaseIterable, Codable {
        case name
        case color
        /// Порядок и группа статуса — одно поле.
        case placement
        case deletedAt
    }

    public func changedFields(comparedTo old: SelectOption) -> Set<Field> {
        var fields: Set<Field> = []
        if name != old.name { fields.insert(.name) }
        if color != old.color { fields.insert(.color) }
        if sortKey != old.sortKey || statusGroup != old.statusGroup { fields.insert(.placement) }
        if deletedAt != old.deletedAt { fields.insert(.deletedAt) }
        return fields
    }
}
