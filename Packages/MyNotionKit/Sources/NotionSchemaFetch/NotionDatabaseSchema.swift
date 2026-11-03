/// Схема одной базы Notion так, как её отдаёт API: типы свойств, варианты с цветами, группы статусов, связи, сводки,
/// формулы. Названия типов и вычислений — уже на языке MyNotion (`PropertyKind`, `Calculation`, форматы числа).
public struct NotionDatabaseSchema: Sendable, Equatable {
    /// 32 hex без дефисов, как в имени файла выгрузки.
    public var databaseId: String
    public var dataSourceId: String
    public var title: String
    /// По названию: порядок столбцов задаёт CSV выгрузки, а не словарь API.
    public var properties: [NotionProperty]

    public init(databaseId: String, dataSourceId: String, title: String, properties: [NotionProperty]) {
        self.databaseId = databaseId
        self.dataSourceId = dataSourceId
        self.title = title
        self.properties = properties
    }

    public func property(named name: String) -> NotionProperty? {
        properties.first { $0.name == name }
    }
}

public struct NotionProperty: Sendable, Equatable {
    /// Без процентного кодирования: так его ждут `rollup_property_id` и ссылки в формулах.
    public var id: String
    public var name: String
    public var kind: Kind

    public init(id: String, name: String, kind: Kind) {
        self.id = id
        self.name = name
        self.kind = kind
    }

    public enum Kind: Sendable, Equatable {
        case title, text, checkbox, url, email, phone, files, date, createdTime, lastEditedTime
        /// `nil` — простое число; иначе номер формата окна «Формат числа» MyNotion (`percent`, `dollar`, `numberWithSeparators`…).
        case number(format: String?)
        case select([NotionOption])
        case multiSelect([NotionOption])
        case status(options: [NotionOption], groups: [NotionStatusGroup])
        case relation(NotionRelation)
        case rollup(NotionRollup)
        case formula(expression: String)
        case uniqueId(prefix: String?)
        /// Люди, кнопка, место, подтверждение и всё, чего нет в MyNotion: остаётся значение из CSV.
        case unsupported(notionType: String)
    }
}

public struct NotionOption: Sendable, Equatable {
    public var name: String
    /// Один из десяти цветов Notion; незнакомый — `default`.
    public var color: String

    public init(name: String, color: String) {
        self.name = name
        self.color = color
    }
}

/// Группа статуса: у Notion их три, по порядку «To-do», «In progress», «Complete».
public struct NotionStatusGroup: Sendable, Equatable {
    public enum Group: String, Sendable, Equatable, CaseIterable {
        case todo, inProgress, complete
    }

    public var group: Group
    public var name: String
    public var optionNames: [String]

    public init(group: Group, name: String, optionNames: [String]) {
        self.group = group
        self.name = name
        self.optionNames = optionNames
    }
}

public struct NotionRelation: Sendable, Equatable {
    public var targetDatabaseId: String?
    public var targetDataSourceId: String?
    /// Название ответного свойства в базе-цели; `nil` — связь односторонняя.
    public var pairedPropertyName: String?
    public var limitsToOne: Bool

    public init(targetDatabaseId: String?, targetDataSourceId: String?, pairedPropertyName: String?, limitsToOne: Bool = false) {
        self.targetDatabaseId = targetDatabaseId
        self.targetDataSourceId = targetDataSourceId
        self.pairedPropertyName = pairedPropertyName
        self.limitsToOne = limitsToOne
    }
}

public struct NotionRollup: Sendable, Equatable {
    public var relationPropertyName: String
    public var targetPropertyName: String
    /// Как называет вычисление Notion (`sum`, `count_per_group`).
    public var function: String
    /// Вычисление MyNotion (`Calculation.rawValue`); `nil` — такого у нас нет.
    public var calculation: String?

    public init(relationPropertyName: String, targetPropertyName: String, function: String, calculation: String?) {
        self.relationPropertyName = relationPropertyName
        self.targetPropertyName = targetPropertyName
        self.function = function
        self.calculation = calculation
    }
}
