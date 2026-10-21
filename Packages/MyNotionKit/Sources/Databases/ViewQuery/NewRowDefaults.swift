import Foundation
import NotesCore

/// Значения новой строки вида (FR-330, contracts/property-types.md): строка получает значения, при которых она видна.
/// Условия «равно», «содержит», «отмечен», «равно дате» дают значение, остальные — пусто; в группе «ИЛИ» — только
/// первое условие. В группе таблицы — ещё и значение группы (оно главнее фильтра по тому же свойству).
public struct NewRowDefaults: Sendable, Hashable {
    /// Название (условие на «Название»); `nil` — пустое.
    public var title: String?
    public var cells: [UUID: JSONValue]

    public init(title: String? = nil, cells: [UUID: JSONValue] = [:]) {
        self.title = title
        self.cells = cells
    }

    public var isEmpty: Bool { title == nil && cells.isEmpty }

    public static func make(filter: FilterNode?, group: (settings: GroupSettings, key: String)? = nil, catalog: DatabaseCatalog,
                            now: Date = Date(), calendar: Calendar = .current) -> NewRowDefaults {
        var defaults = NewRowDefaults()
        for condition in applicable(filter) {
            guard let property = catalog.propertiesById[condition.propertyId] else { continue }
            defaults.apply(condition, property: property, catalog: catalog, now: now, calendar: calendar)
        }
        if let group, group.key != GroupSettings.emptyKey, let property = catalog.propertiesById[group.settings.propertyId],
           let value = groupValue(group.key, settings: group.settings, property: property, catalog: catalog) {
            if property.kind == .title, let title = value.string { defaults.title = title } else { defaults.cells[property.id] = value }
        }
        return defaults
    }

    /// Условия, которые должна выполнить строка: все в «И», первое в «ИЛИ».
    static func applicable(_ node: FilterNode?) -> [FilterCondition] {
        switch node {
        case nil: []
        case .condition(let condition)?: [condition]
        case .and(let items)?: items.flatMap { applicable($0) }
        case .or(let items)?: items.first.map { applicable($0) } ?? []
        }
    }

    private mutating func apply(_ condition: FilterCondition, property: DatabaseProperty, catalog: DatabaseCatalog, now: Date, calendar: Calendar) {
        let value = condition.value
        switch property.kind {
        case .title:
            if [.is, .contains, .startsWith, .endsWith].contains(condition.op), let text = value.string, !text.isEmpty { title = text }
        case .text:
            if [.is, .contains, .startsWith, .endsWith].contains(condition.op), let text = value.string, !text.isEmpty {
                cells[property.id] = ["runs": [], "string": .string(text)]
            }
        case .url, .email, .phone:
            if [.is, .contains, .startsWith, .endsWith].contains(condition.op), let text = value.string, !text.isEmpty { cells[property.id] = .string(text) }
        case .number:
            if [.equals, .is].contains(condition.op), let number = value.number { cells[property.id] = .number(number) }
        case .select, .status:
            if condition.op == .is, let id = value.array?.first?.string ?? value.string { cells[property.id] = .string(id) }
            if condition.op == .isInGroup, let group = value.string.flatMap(StatusGroup.init(rawValue:)),
               let option = (catalog.options[property.id] ?? []).first(where: { $0.statusGroup == group }) {
                cells[property.id] = .string(option.id.databaseText)
            }
        case .multiSelect:
            if [.contains, .is].contains(condition.op) {
                let ids = value.array?.compactMap(\.string) ?? value.string.map { [$0] } ?? []
                if !ids.isEmpty { cells[property.id] = .array(ids.map(JSONValue.string)) }
            }
        case .checkbox:
            if condition.op == .is, value.bool == true { cells[property.id] = .bool(true) }
        case .date:
            if condition.op == .is, let day = Self.day(value, now: now, calendar: calendar) {
                cells[property.id] = ["start": .string(day), "hasTime": false]
            }
        default:
            break
        }
    }

    /// Значение свойства у строк группы: вариант, флажок, текст, день.
    static func groupValue(_ key: String, settings: GroupSettings, property: DatabaseProperty, catalog: DatabaseCatalog) -> JSONValue? {
        let options = catalog.options[property.id] ?? []
        switch property.kind {
        case .select:
            return options.contains { $0.id.databaseText == key } ? .string(key) : nil
        case .status:
            if settings.bucket?.string == "group" {
                return options.first { $0.statusGroup?.rawValue == key }.map { .string($0.id.databaseText) }
            }
            return options.contains { $0.id.databaseText == key } ? .string(key) : nil
        case .multiSelect:
            return options.contains { $0.id.databaseText == key } ? .array([.string(key)]) : nil
        case .checkbox:
            return key == "checked" ? .bool(true) : nil
        case .date:
            // День — значением; неделя, месяц и «относительно» — без значения (Notion так же).
            let parts = key.split(separator: "-")
            return parts.count == 3 && !key.contains("W") ? ["start": .string(key), "hasTime": false] : nil
        default:
            return nil
        }
    }

    /// День значения фильтра даты: относительный («Сегодня», «Через неделю»…) или точный.
    static func day(_ value: JSONValue, now: Date, calendar: Calendar) -> String? {
        let today = calendar.startOfDay(for: now)
        var date: Date?
        if let relative = value["relative"]?.string {
            let shift: (Calendar.Component, Int) = switch relative {
            case "tomorrow": (.day, 1)
            case "yesterday": (.day, -1)
            case "oneWeekAgo": (.day, -7)
            case "oneWeekFromNow": (.day, 7)
            case "oneMonthAgo": (.month, -1)
            case "oneMonthFromNow": (.month, 1)
            default: (.day, 0)
            }
            date = calendar.date(byAdding: shift.0, value: shift.1, to: today)
        } else if let text = value["exact"]?.string ?? value.string {
            return String(text.prefix(10))
        }
        guard let date else { return nil }
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
}
