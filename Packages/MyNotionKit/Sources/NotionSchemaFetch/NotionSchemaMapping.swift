import Foundation

public enum NotionSchemaMappingError: Error, Equatable {
    /// Ответ — не JSON или не тот объект Notion.
    case unreadable
}

public struct NotionDataSourceReference: Sendable, Equatable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Ответ `GET /v1/databases/{id}`: у новых версий API — список источников данных, у старых — сразу свойства.
public struct NotionDatabaseReference: Sendable, Equatable {
    public var id: String
    public var title: String
    public var dataSources: [NotionDataSourceReference]
    public var inlineSchema: NotionDatabaseSchema?
}

/// Ответы Notion API → схема (research R19). Только чтение JSON: сети здесь нет.
public enum NotionSchemaMapping {
    /// 32 hex без дефисов, нижний регистр.
    public static func normalizedId(_ id: String) -> String {
        id.replacingOccurrences(of: "-", with: "").lowercased()
    }

    public static func databaseReference(from data: Data) throws -> NotionDatabaseReference {
        let object = try jsonObject(data)
        guard object["object"] as? String == "database", let id = object["id"] as? String else { throw NotionSchemaMappingError.unreadable }
        let dataSources = (object["data_sources"] as? [[String: Any]] ?? []).compactMap { source -> NotionDataSourceReference? in
            guard let sourceId = source["id"] as? String else { return nil }
            return NotionDataSourceReference(id: normalizedId(sourceId), name: source["name"] as? String ?? "")
        }
        var inline: NotionDatabaseSchema?
        if object["properties"] is [String: Any] {
            inline = schema(from: object, databaseId: normalizedId(id), dataSourceId: normalizedId(id))
        }
        return NotionDatabaseReference(id: normalizedId(id), title: plainText(object["title"]), dataSources: dataSources, inlineSchema: inline)
    }

    public static func schema(fromDataSource data: Data) throws -> NotionDatabaseSchema {
        let object = try jsonObject(data)
        guard object["object"] as? String == "data_source", let id = object["id"] as? String else { throw NotionSchemaMappingError.unreadable }
        let parent = (object["parent"] as? [String: Any])?["database_id"] as? String ?? ""
        return schema(from: object, databaseId: normalizedId(parent), dataSourceId: normalizedId(id))
    }

    private static func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw NotionSchemaMappingError.unreadable }
        return object
    }

    private static func schema(from object: [String: Any], databaseId: String, dataSourceId: String) -> NotionDatabaseSchema {
        let properties = (object["properties"] as? [String: Any] ?? [:]).compactMap { key, value -> NotionProperty? in
            guard let property = value as? [String: Any] else { return nil }
            let name = property["name"] as? String ?? key
            let id = (property["id"] as? String).map { $0.removingPercentEncoding ?? $0 } ?? name
            let type = property["type"] as? String ?? ""
            return NotionProperty(id: id, name: name, kind: kind(ofType: type, payload: property[type] as? [String: Any] ?? [:]))
        }.sorted { $0.name < $1.name }
        return NotionDatabaseSchema(databaseId: databaseId, dataSourceId: dataSourceId, title: plainText(object["title"]), properties: properties)
    }

    private static func plainText(_ value: Any?) -> String {
        (value as? [[String: Any]] ?? []).compactMap { $0["plain_text"] as? String }.joined()
    }

    private static func kind(ofType type: String, payload: [String: Any]) -> NotionProperty.Kind {
        switch type {
        case "title": return .title
        case "rich_text": return .text
        case "checkbox": return .checkbox
        case "url": return .url
        case "email": return .email
        case "phone_number": return .phone
        case "files": return .files
        case "date": return .date
        case "created_time": return .createdTime
        case "last_edited_time": return .lastEditedTime
        case "number": return .number(format: numberFormat(payload["format"] as? String))
        case "select": return .select(options(payload))
        case "multi_select": return .multiSelect(options(payload))
        case "status": return statusKind(payload)
        case "unique_id": return .uniqueId(prefix: (payload["prefix"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        case "formula": return .formula(expression: payload["expression"] as? String ?? "")
        case "relation": return .relation(relation(payload))
        case "rollup": return .rollup(rollup(payload))
        default: return .unsupported(notionType: type)
        }
    }

    // MARK: Варианты и статусы

    private static let colors: Set<String> = ["default", "gray", "brown", "orange", "yellow", "green", "blue", "purple", "pink", "red"]

    private static func options(_ payload: [String: Any]) -> [NotionOption] {
        (payload["options"] as? [[String: Any]] ?? []).compactMap { option in
            guard let name = option["name"] as? String else { return nil }
            let color = option["color"] as? String ?? "default"
            return NotionOption(name: name, color: colors.contains(color) ? color : "default")
        }
    }

    private static func statusKind(_ payload: [String: Any]) -> NotionProperty.Kind {
        let raw = payload["options"] as? [[String: Any]] ?? []
        var namesById: [String: String] = [:]
        for option in raw { if let id = option["id"] as? String, let name = option["name"] as? String { namesById[id] = name } }
        let groups = (payload["groups"] as? [[String: Any]] ?? []).enumerated().map { position, group in
            NotionStatusGroup(group: NotionStatusGroup.Group.allCases[min(position, NotionStatusGroup.Group.allCases.count - 1)],
                              name: group["name"] as? String ?? "",
                              optionNames: (group["option_ids"] as? [String] ?? []).compactMap { namesById[$0] })
        }
        return .status(options: options(payload), groups: groups)
    }

    // MARK: Число

    /// Форматы окна «Формат числа» MyNotion (`NumberDisplay.formats`) без «number».
    private static let numberFormats: Set<String> = [
        "numberWithSeparators", "percent", "dollar", "australianDollar", "canadianDollar", "singaporeDollar", "euro", "pound", "yen", "ruble",
        "rupee", "won", "yuan", "real", "lira", "rupiah", "franc", "hongKongDollar", "newZealandDollar", "krona", "norwegianKrone",
        "mexicanPeso", "rand", "newTaiwanDollar", "danishKrone", "zloty", "baht", "forint", "koruna", "shekel", "chileanPeso",
        "philippinePeso", "dirham", "colombianPeso", "riyal", "ringgit", "leu", "argentinePeso", "uruguayanPeso", "peruvianSol",
    ]

    private static func numberFormat(_ notion: String?) -> String? {
        guard let notion else { return nil }
        let words = notion.split(separator: "_").map(String.init)
        let camel = (words.first ?? "") + words.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
        let mine = camel == "numberWithCommas" ? "numberWithSeparators" : camel
        return numberFormats.contains(mine) ? mine : nil
    }

    // MARK: Связь и сводка

    private static func relation(_ payload: [String: Any]) -> NotionRelation {
        let dual = payload["dual_property"] as? [String: Any]
        return NotionRelation(targetDatabaseId: (payload["database_id"] as? String).map(normalizedId),
                              targetDataSourceId: (payload["data_source_id"] as? String).map(normalizedId),
                              pairedPropertyName: payload["type"] as? String == "dual_property" ? dual?["synced_property_name"] as? String : nil,
                              limitsToOne: (payload["limit"] as? Int) == 1)
    }

    private static let calculations: [String: String] = [
        "count_all": "countAll", "count": "countAll", "count_values": "countValues", "count_unique_values": "countUnique",
        "count_empty": "countEmpty", "count_not_empty": "countNotEmpty", "unique": "showUnique", "show_unique": "showUnique",
        "percent_empty": "percentEmpty", "percent_not_empty": "percentNotEmpty", "sum": "sum", "average": "average", "median": "median",
        "min": "min", "max": "max", "range": "range", "earliest_date": "earliestDate", "latest_date": "latestDate", "date_range": "dateRange",
        "checked": "checked", "unchecked": "unchecked", "percent_checked": "percentChecked", "percent_unchecked": "percentUnchecked",
        "show_original": "showOriginal",
    ]

    private static func rollup(_ payload: [String: Any]) -> NotionRollup {
        let function = payload["function"] as? String ?? ""
        return NotionRollup(relationPropertyName: payload["relation_property_name"] as? String ?? "",
                            targetPropertyName: payload["rollup_property_name"] as? String ?? "",
                            function: function, calculation: calculations[function])
    }
}
