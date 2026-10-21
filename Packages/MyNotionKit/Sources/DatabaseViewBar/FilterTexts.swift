import Databases
import Foundation
import NotesCore

/// Подписи фильтра и сортировки (contracts/property-types.md, «Условия фильтра»; названия Notion 7.39 по-русски):
/// условия в меню, текст плашки «Свойство: значение», плашка сортировки.
public enum FilterTexts {
    /// Условие в меню окна фильтра.
    public static func title(of op: FilterOperator, kind: PropertyKind) -> String {
        switch op {
        case .is: "Равно"
        case .isNot: "Не равно"
        case .contains: "Содержит"
        case .doesNotContain: "Не содержит"
        case .startsWith: "Начинается с"
        case .endsWith: "Заканчивается на"
        case .isEmpty: "Пусто"
        case .isNotEmpty: "Не пусто"
        case .equals: "="
        case .notEquals: "≠"
        case .greaterThan: ">"
        case .lessThan: "<"
        case .greaterThanOrEqual: "≥"
        case .lessThanOrEqual: "≤"
        case .isBefore: "До"
        case .isAfter: "После"
        case .isOnOrBefore: "Не позже"
        case .isOnOrAfter: "Не раньше"
        case .isBetween: "Между"
        case .isRelativeToToday: "Относительно сегодня"
        case .isInGroup: "В группе"
        default: op.rawValue
        }
    }

    /// Условие без значения (пусто, не пусто): у плашки нет «:».
    public static func needsValue(_ op: FilterOperator) -> Bool { op != .isEmpty && op != .isNotEmpty }

    /// Значения дат фильтра («Сегодня», «Через неделю»…) по порядку меню.
    public static let relativeDates: [(key: String, title: String)] = [
        ("today", "Сегодня"), ("tomorrow", "Завтра"), ("yesterday", "Вчера"), ("oneWeekAgo", "Неделю назад"),
        ("oneWeekFromNow", "Через неделю"), ("oneMonthAgo", "Месяц назад"), ("oneMonthFromNow", "Через месяц"),
    ]

    /// «Относительно сегодня»: прошлые / следующие / этот; день, неделя, месяц, год.
    public static let relativeDirections: [(key: String, title: String)] = [("past", "Прошлые"), ("next", "Следующие"), ("this", "Этот")]
    public static let relativeUnits: [(key: String, title: String)] = [("day", "День"), ("week", "Неделя"), ("month", "Месяц"), ("year", "Год")]

    /// Текст значения условия: варианты по названиям, дата словами, число и текст как есть; пусто — `nil`.
    public static func valueText(_ condition: FilterCondition, catalog: DatabaseCatalog) -> String? {
        let value = condition.value
        guard let property = catalog.propertiesById[condition.propertyId] else { return nil }
        switch property.kind {
        case .select, .status, .multiSelect:
            if condition.op == .isInGroup, let group = value.string.flatMap(StatusGroup.init(rawValue:)) {
                return ["todo": "К выполнению", "inProgress": "В работе", "complete": "Завершено"][group.rawValue]
            }
            let ids = value.array?.compactMap(\.string) ?? value.string.map { [$0] } ?? []
            let names = ids.compactMap { UUID(uuidString: $0).flatMap { catalog.optionsById[$0]?.name } }
            return names.isEmpty ? nil : names.joined(separator: ", ")
        case .checkbox:
            return value.bool == false ? "Не отмечено" : "Отмечено"
        case .date, .createdTime, .lastEditedTime:
            return dateText(value, op: condition.op)
        case .number, .uniqueId:
            return value.number.map { NumberFormatter.localizedString(from: NSNumber(value: $0), number: .decimal) }
        case .relation:
            let count = value.array?.count ?? (value.string == nil ? 0 : 1)
            return count == 0 ? nil : "\(count)"
        default:
            return value.string.flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    static func dateText(_ value: JSONValue, op: FilterOperator) -> String? {
        if op == .isRelativeToToday {
            let direction = relativeDirections.first { $0.key == value["direction"]?.string }?.title ?? "Этот"
            let unit = relativeUnits.first { $0.key == value["unit"]?.string }?.title.lowercased() ?? "неделя"
            let count = Int(value["count"]?.number ?? 1)
            return direction == "Этот" ? "\(direction) \(unit)" : "\(direction) \(count) \(unit)"
        }
        if op == .isBetween, let start = value["start"]?["exact"]?.string ?? value["start"]?.string,
           let end = value["end"]?["exact"]?.string ?? value["end"]?.string {
            return "\(start) – \(end)"
        }
        if let relative = value["relative"]?.string { return relativeDates.first { $0.key == relative }?.title }
        return value["exact"]?.string ?? value.string
    }

    /// Текст плашки простого фильтра: «Статус: Готово», «Часы: > 2», «Срок: до Сегодня», «Описание: пусто»; без значения —
    /// только имя свойства (плашка серая).
    public static func chipText(_ condition: FilterCondition, catalog: DatabaseCatalog) -> (text: String, isActive: Bool) {
        guard let property = catalog.propertiesById[condition.propertyId] else { return ("?", false) }
        guard needsValue(condition.op) else { return ("\(property.name): \(title(of: condition.op, kind: property.kind).lowercased())", true) }
        guard let value = valueText(condition, catalog: catalog) else { return (property.name, false) }
        let prefix: String = switch condition.op {
        case .is, .equals: ""
        case .contains where property.kind == .multiSelect: ""
        case .isNot: "не "
        default: title(of: condition.op, kind: property.kind).lowercased() + " "
        }
        return ("\(property.name): \(prefix)\(value)", true)
    }

    /// «1 правило», «2 правила», «5 правил».
    public static func rules(_ count: Int) -> String {
        "\(count) " + plural(count, "правило", "правила", "правил")
    }

    /// «2 сортировки», «5 сортировок».
    public static func sorts(_ count: Int) -> String {
        "\(count) " + plural(count, "сортировка", "сортировки", "сортировок")
    }

    static func plural(_ count: Int, _ one: String, _ few: String, _ many: String) -> String {
        let last = count % 10, lastTwo = count % 100
        if last == 1 && lastTwo != 11 { return one }
        if (2...4).contains(last) && !(12...14).contains(lastTwo) { return few }
        return many
    }

    /// Направление сортировки: у текста «А → Я / Я → А», у остальных — «По возрастанию / По убыванию».
    public static func direction(_ ascending: Bool, kind: PropertyKind) -> String {
        let textual: Set<PropertyKind> = [.title, .text, .url, .email, .phone, .select, .multiSelect, .status]
        if textual.contains(kind) { return ascending ? "А → Я" : "Я → А" }
        return ascending ? "По возрастанию" : "По убыванию"
    }
}
