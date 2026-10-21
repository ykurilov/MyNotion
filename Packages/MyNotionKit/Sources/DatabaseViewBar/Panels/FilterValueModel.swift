import Databases
import Foundation
import NotesCore

/// Вариант в окне значения фильтра: флажок, плашка.
public struct FilterOptionItem: Sendable, Hashable {
    public let id: UUID
    public let name: String
    public let color: OptionColor
    public let isSelected: Bool
}

/// Значение даты фильтра: не выбрано, словами («Сегодня»), точная дата.
public enum FilterDateChoice: Sendable, Hashable {
    case unset
    case relative(String)
    case exact(String)
}

/// Что показывает окно значения условия (простой фильтр и строка расширенного).
public enum FilterValueEditor: Sendable, Hashable {
    /// Пусто / не пусто, файлы, связь (строки связи выбирает US4).
    case none
    case text(String)
    case number(String)
    /// Флажки вариантов (можно несколько).
    case options([FilterOptionItem])
    /// «В группе» у статуса: одна из трёх групп.
    case statusGroup(StatusGroup?)
    case checkbox(Bool)
    case date(FilterDateChoice)
    /// «Между»: две точные даты ГГГГ-ММ-ДД.
    case dateRange(start: String, end: String)
    /// «Относительно сегодня»: прошлые / следующие / этот, N, день / неделя / месяц / год.
    case relative(direction: String, count: Int, unit: String)
}

/// Окно значения фильтра без отрисовки: условия меню, что показать, какое значение записать.
public enum FilterValues {
    /// Группы статуса по порядку и их названия.
    public static let statusGroups: [(group: StatusGroup, title: String)] = [
        (.todo, "К выполнению"), (.inProgress, "В работе"), (.complete, "Завершено"),
    ]

    /// Значения даты меню по порядку и «Точная дата».
    public static let dateChoices: [(key: String, title: String)] = FilterTexts.relativeDates + [("exact", "Точная дата")]

    public static func editor(for condition: FilterCondition, catalog: DatabaseCatalog, query: String = "") -> FilterValueEditor {
        guard let property = catalog.propertiesById[condition.propertyId], FilterTexts.needsValue(condition.op) else { return .none }
        let value = condition.value
        switch FilterValueKind(property) {
        case .text, .list:
            return .text(value.string ?? "")
        case .number:
            return .number(value.number.map(plain) ?? "")
        case .checkbox:
            return .checkbox(value.bool ?? true)
        case .options:
            if condition.op == .isInGroup { return .statusGroup(value.string.flatMap(StatusGroup.init(rawValue:))) }
            let selected = Set(selectedIds(value))
            let query = query.trimmingCharacters(in: .whitespaces)
            let options = (catalog.options[property.id] ?? []).filter {
                query.isEmpty || $0.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
            return .options(options.map { FilterOptionItem(id: $0.id, name: $0.name, color: $0.optionColor, isSelected: selected.contains($0.id)) })
        case .date:
            switch condition.op {
            case .isBetween:
                return .dateRange(start: exact(value["start"]) ?? "", end: exact(value["end"]) ?? "")
            case .isRelativeToToday:
                return .relative(direction: value["direction"]?.string ?? "this", count: Int(value["count"]?.number ?? 1),
                                 unit: value["unit"]?.string ?? "week")
            default:
                if let relative = value["relative"]?.string { return .date(.relative(relative)) }
                if let exact = exact(value) { return .date(.exact(exact)) }
                return .date(.unset)
            }
        case .relation, .files:
            return .none
        }
    }

    /// Выбранные варианты: id строкой или списком.
    public static func selectedIds(_ value: JSONValue) -> [UUID] {
        (value.array?.compactMap(\.string) ?? value.string.map { [$0] } ?? []).compactMap(UUID.init(uuidString:))
    }

    private static func exact(_ value: JSONValue?) -> String? { value?["exact"]?.string ?? value?.string }

    static func plain(_ number: Double) -> String {
        number.rounded() == number && abs(number) < 1e15 ? String(Int64(number)) : String(number)
    }

    // MARK: Правки условия

    /// Другое условие в меню: значение остаётся, если подходит, иначе — значение по умолчанию нового условия.
    public static func changingOperator(_ condition: FilterCondition, to op: FilterOperator, catalog: DatabaseCatalog) -> FilterCondition {
        var result = condition
        result.op = op
        guard op != condition.op, let property = catalog.propertiesById[condition.propertyId] else { return result }
        guard FilterTexts.needsValue(op) else {
            result.value = .null
            return result
        }
        switch FilterValueKind(property) {
        case .date:
            let shaped: Set<FilterOperator> = [.isBetween, .isRelativeToToday]
            if op == .isRelativeToToday {
                result.value = ["direction": "this", "count": 1, "unit": "week"]
            } else if shaped.contains(op) || shaped.contains(condition.op) || !FilterTexts.needsValue(condition.op) {
                result.value = .null
            }
        case .options:
            if op == .isInGroup || condition.op == .isInGroup { result.value = .null }
        case .checkbox:
            if result.value.bool == nil { result.value = .bool(true) }
        default:
            break
        }
        return result
    }

    /// Другое свойство у правила расширенного фильтра: условие по умолчанию нового свойства.
    public static func changingProperty(_ condition: FilterCondition, to property: DatabaseProperty) -> FilterCondition {
        condition.propertyId == property.id ? condition : FilterEditing.defaultCondition(for: property)
    }

    /// Текст или формула-текст: пусто — без значения.
    public static func text(_ text: String) -> JSONValue { text.isEmpty ? .null : .string(text) }

    /// Число из поля (точка или запятая); не число — без значения.
    public static func number(_ text: String) -> JSONValue {
        var trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "")
        if !trimmed.contains("."), trimmed.filter({ $0 == "," }).count == 1 { trimmed = trimmed.replacingOccurrences(of: ",", with: ".") }
        return Double(trimmed).map(JSONValue.number) ?? .null
    }

    /// Флажок варианта: вариант добавляется в список или уходит из него; пустой список — без значения.
    public static func toggling(_ optionId: UUID, in value: JSONValue) -> JSONValue {
        var ids = selectedIds(value)
        if let index = ids.firstIndex(of: optionId) { ids.remove(at: index) } else { ids.append(optionId) }
        return ids.isEmpty ? .null : .array(ids.map { .string($0.databaseText) })
    }

    public static func statusGroup(_ group: StatusGroup) -> JSONValue { .string(group.rawValue) }

    /// Дата словами («today»…) или «exact» — точная (сегодняшняя, пока не введена другая).
    public static func dateChoice(_ key: String, today: Date = Date(), calendar: Calendar = .current) -> JSONValue {
        key == "exact" ? ["exact": .string(dayText(today, calendar: calendar))] : ["relative": .string(key)]
    }

    /// Точная дата из поля ГГГГ-ММ-ДД; иначе `nil` — не записывать.
    public static func exactDate(_ text: String) -> JSONValue? {
        validDay(text).map { ["exact": .string($0)] }
    }

    /// «Между»: обе даты ГГГГ-ММ-ДД; неполное — `nil`.
    public static func dateRange(start: String, end: String) -> JSONValue? {
        guard let start = validDay(start), let end = validDay(end) else { return nil }
        return ["start": ["exact": .string(start)], "end": ["exact": .string(end)]]
    }

    /// «Относительно сегодня»: N не меньше 1.
    public static func relative(direction: String, count: Int, unit: String) -> JSONValue {
        ["direction": .string(direction), "count": .number(Double(max(count, 1))), "unit": .string(unit)]
    }

    static func validDay(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        guard trimmed.count == 10, let date = formatter.date(from: trimmed) else { return nil }
        return formatter.string(from: date) == trimmed ? trimmed : nil
    }

    static func dayText(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 2000, parts.month ?? 1, parts.day ?? 1)
    }
}

/// Списки свойств окон: «Фильтр по…», «Сортировать по…», «Группировать по» — по алфавиту, с поиском.
public enum PropertyChoices {
    public static func alphabetical(_ properties: [DatabaseProperty], matching query: String = "") -> [DatabaseProperty] {
        let query = query.trimmingCharacters(in: .whitespaces)
        return properties
            .filter { query.isEmpty || $0.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public static func forFilter(_ catalog: DatabaseCatalog, matching query: String = "") -> [DatabaseProperty] {
        alphabetical(catalog.properties, matching: query)
    }

    /// Для сортировки — свойства, по которым ещё нет уровня.
    public static func forSort(_ catalog: DatabaseCatalog, excluding used: Set<UUID>, matching query: String = "") -> [DatabaseProperty] {
        alphabetical(catalog.properties.filter { !used.contains($0.id) }, matching: query)
    }

    /// Группировать можно не по всем: нет ID и файлов.
    public static func forGroup(_ catalog: DatabaseCatalog) -> [DatabaseProperty] {
        alphabetical(catalog.properties.filter { PropertyTypes.type(for: $0.kind).isGroupable })
    }
}
