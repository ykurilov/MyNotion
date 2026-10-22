import Foundation
import NotesCore

/// Заголовок группы: плашка варианта, текст или серое «Нет …».
public enum GroupLabel: Sendable, Hashable {
    case option(name: String, color: OptionColor)
    case text(String)
    case empty(String)

    public var title: String {
        switch self {
        case .option(let name, _), .text(let name), .empty(let name): name
        }
    }
}

/// Группа строк вида (contracts/property-types.md, «Группировка»): строки по порядку сортировок, скрыта ли, свёрнута ли.
public struct ViewGroup: Sendable, Hashable {
    public var key: String
    public var label: GroupLabel
    public var rowIds: [UUID]
    public var isHidden: Bool
    public var isCollapsed: Bool

    public var isEmpty: Bool { rowIds.isEmpty }
}

/// Строки по группам (после фильтра, поиска и сортировок — порядок внутри группы сохраняется). Множественный выбор и
/// связь кладут строку в каждую свою группу. Группы — все возможные (варианты без строк тоже): список групп в
/// настройках показывает их все, таблица прячет пустые по «Скрывать пустые группы».
public enum ViewGrouping {
    public static func groups(rowIds: [UUID], values: [UUID: JSONValue], settings: GroupSettings, context: PropertyContext) -> [ViewGroup] {
        let type = PropertyTypes.type(for: context.property.kind)
        var rowsByKey: [String: [UUID]] = [:]
        var firstValue: [String: JSONValue] = [:]
        for rowId in rowIds {
            let value = values[rowId]
            let keys = type.groupKeys(value, in: context, bucket: settings.bucket)
            for key in keys.isEmpty ? [GroupSettings.emptyKey] : uniqued(keys) {
                rowsByKey[key, default: []].append(rowId)
                if firstValue[key] == nil, let value { firstValue[key] = value }
            }
        }
        var keys = naturalKeys(settings: settings, context: context, found: Array(rowsByKey.keys))
        let labels = Dictionary(uniqueKeysWithValues: keys.map { ($0, label(of: $0, settings: settings, context: context, sample: firstValue[$0])) })
        switch settings.groupSort {
        case .manual:
            let stored = settings.groups.map(\.key).filter { labels[$0] != nil }
            let storedSet = Set(stored)
            keys = stored + keys.filter { !storedSet.contains($0) }
        case .alphabetical, .reverseAlphabetical:
            let rest = keys.filter { $0 != GroupSettings.emptyKey }.sorted {
                labels[$0]!.title.localizedStandardCompare(labels[$1]!.title) == (settings.groupSort == .alphabetical ? .orderedAscending : .orderedDescending)
            }
            keys = (keys.contains(GroupSettings.emptyKey) ? [GroupSettings.emptyKey] : []) + rest
        }
        return keys.map { key in
            let state = settings.state(of: key)
            return ViewGroup(key: key, label: labels[key]!, rowIds: rowsByKey[key] ?? [], isHidden: state.isHidden, isCollapsed: state.isCollapsed)
        }
    }

    /// Группы, которые показывает таблица: не скрытые и (при «Скрывать пустые группы») не пустые.
    public static func shown(_ groups: [ViewGroup], hideEmpty: Bool) -> [ViewGroup] {
        groups.filter { !$0.isHidden && !(hideEmpty && $0.isEmpty) }
    }

    private static func uniqued(_ keys: [String]) -> [String] {
        var seen: Set<String> = []
        return keys.filter { seen.insert($0).inserted }
    }

    /// Все ключи в естественном порядке: «Нет …» первой (Notion), затем варианты по их порядку или найденные значения
    /// по возрастанию.
    static func naturalKeys(settings: GroupSettings, context: PropertyContext, found: [String]) -> [String] {
        let kind = context.property.kind
        var keys: [String]
        switch kind {
        case .select, .multiSelect:
            keys = context.options.map(\.id.databaseText)
        case .status:
            keys = settings.bucket?.string == "group" ? StatusGroup.allCases.map(\.rawValue) : context.options.map(\.id.databaseText)
        case .checkbox:
            keys = ["unchecked", "checked"]
        case .number:
            keys = found.filter { !$0.isEmpty }.sorted { numberBucketStart($0) < numberBucketStart($1) }
        case .date, .createdTime, .lastEditedTime:
            keys = found.filter { !$0.isEmpty }.sorted { dateKeyOrder($0) < dateKeyOrder($1) }
        default:
            keys = found.filter { !$0.isEmpty }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
        let listed = Set(keys)
        // Значения, которых нет в списке (вариант удалён на другом Mac), — в конце.
        keys += found.filter { !$0.isEmpty && !listed.contains($0) }.sorted()
        return [GroupSettings.emptyKey] + keys
    }

    static func numberBucketStart(_ key: String) -> Double {
        if key.hasPrefix("<") { return -.infinity }
        if key.hasSuffix("+") { return Double(key.dropLast()) ?? .infinity }
        let separator = key.dropFirst().firstIndex(of: "-") ?? key.endIndex
        return Double(key[..<separator]) ?? 0
    }

    private static let relativeOrder = ["past30", "past7", "yesterday", "today", "tomorrow", "next7", "next30"]

    static func dateKeyOrder(_ key: String) -> String {
        // «Относительно»: прошлые месяцы раньше прошлых 30 дней, будущие месяцы — после следующих 30 дней.
        if let index = relativeOrder.firstIndex(of: key) { return "R\(index)" }
        return key
    }

    // MARK: Заголовки

    public static func label(of key: String, settings: GroupSettings, context: PropertyContext, sample: JSONValue? = nil) -> GroupLabel {
        let property = context.property
        if key == GroupSettings.emptyKey {
            return .empty([.date, .createdTime, .lastEditedTime].contains(property.kind) ? "Без даты" : "Нет «\(property.name)»")
        }
        switch property.kind {
        case .select, .multiSelect, .status:
            if property.kind == .status, settings.bucket?.string == "group", let group = StatusGroup(rawValue: key) {
                let configured = property.config["groups"]?.array?.first { $0["id"]?.string == key }
                let color = configured?["color"]?.string.flatMap(OptionColor.init(rawValue:)) ?? .gray
                return .option(name: configured?["name"]?.string ?? group.defaultName, color: color)
            }
            guard let option = context.options.first(where: { $0.id.databaseText == key }) else { return .text(key) }
            return .option(name: option.name, color: option.optionColor)
        case .checkbox:
            return .text(key == "checked" ? "Отмечено" : "Не отмечено")
        case .date, .createdTime, .lastEditedTime:
            return .text(dateTitle(key, context: context))
        case .number:
            return .text(numberTitle(key))
        case .relation:
            let title = sample?.array?.first { $0["id"]?.string == key }?["title"]?.string
            return .text(title.map { $0.isEmpty ? Page.untitledTitle : $0 } ?? key)
        default:
            // Ключ текста — сравнимый (без регистра); заголовок — как написано в первой строке группы.
            let shown = sample.map { PropertyTypes.type(for: property.kind).displayText($0, in: context) }
            return .text(shown.flatMap { $0.isEmpty ? nil : $0 } ?? key)
        }
    }

    static func numberTitle(_ key: String) -> String {
        if key.hasPrefix("<") { return "< " + key.dropFirst() }
        if key.hasSuffix("+") { return "≥ " + key.dropLast() }
        guard let separator = key.dropFirst().firstIndex(of: "-") else { return key }
        return key[..<separator] + " – " + key[key.index(after: separator)...]
    }

    static func dateTitle(_ key: String, context: PropertyContext) -> String {
        switch key {
        case "today": return "Сегодня"
        case "yesterday": return "Вчера"
        case "tomorrow": return "Завтра"
        case "past7": return "Прошлые 7 дней"
        case "next7": return "Следующие 7 дней"
        case "past30": return "Прошлые 30 дней"
        case "next30": return "Следующие 30 дней"
        default: break
        }
        let zone = context.calendar.timeZone
        let parts = key.split(separator: "-")
        if parts.count == 2, parts[1].hasPrefix("W"), let year = Int(parts[0]), let week = Int(parts[1].dropFirst()) {
            var iso = Calendar(identifier: .iso8601)
            iso.timeZone = zone
            guard let monday = iso.date(from: DateComponents(weekday: 2, weekOfYear: week, yearForWeekOfYear: year)) else { return key }
            return "Неделя с " + Formatters.date(context.locale, zone, pattern: "d MMM yyyy").string(from: monday)
        }
        let numbers = parts.compactMap { Int($0) }
        var calendar = context.calendar
        calendar.timeZone = zone
        switch numbers.count {
        case 3:
            guard let day = calendar.date(from: DateComponents(year: numbers[0], month: numbers[1], day: numbers[2])) else { return key }
            return Formatters.date(context.locale, zone, pattern: "d MMM yyyy").string(from: day)
        case 2:
            guard let month = calendar.date(from: DateComponents(year: numbers[0], month: numbers[1], day: 1)) else { return key }
            return Formatters.date(context.locale, zone, pattern: "LLLL yyyy").string(from: month).capitalizedFirst
        default:
            return key
        }
    }
}

extension StatusGroup {
    /// Название группы статуса по умолчанию (contracts/property-types.md, «Цвета вариантов»).
    var defaultName: String {
        switch self {
        case .todo: "К выполнению"
        case .inProgress: "В работе"
        case .complete: "Завершено"
        }
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
