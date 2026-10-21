import Foundation
import GRDB
import NotesCore

/// Итог колонки, готовый к показу: подпись мелкими заглавными и значение («КОЛИЧЕСТВО 5»).
public struct ColumnTotal: Sendable, Hashable {
    public var label: String
    public var value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

/// Итоги колонок вида (Q1, contracts/property-types.md, «Итоги колонки»): по строкам после фильтра и поиска, у каждой
/// группы — свои. Одно чтение значений на колонку с итогом.
public enum ColumnTotals {
    /// Итоги всех колонок с вычислением: под таблицей (`overall`) и под каждой группой (по ключу группы).
    public struct Result: Sendable, Hashable {
        public var overall: [UUID: ColumnTotal] = [:]
        public var groups: [String: [UUID: ColumnTotal]] = [:]
        public init() {}
    }

    public static func compute(view: DatabaseView, catalog: DatabaseCatalog, rowIds: [UUID], groups: [ViewGroup]?, in db: Database) throws -> Result {
        var result = Result()
        for propertyId in ViewQuery.visiblePropertyIds(of: view, catalog: catalog) {
            guard let calculation = view.calculation(of: propertyId), let property = catalog.propertiesById[propertyId] else { continue }
            let context = catalog.context(for: property)
            let values = try PropertyValues.read(property, of: catalog.databaseId, context: context, in: db)
            result.overall[propertyId] = total(calculation, values: rowIds.map { values[$0] }, context: context)
            for group in groups ?? [] {
                result.groups[group.key, default: [:]][propertyId] = total(calculation, values: group.rowIds.map { values[$0] }, context: context)
            }
        }
        return result
    }

    /// Итог по значениям строк для показа.
    public static func total(_ calculation: Calculation, values: [JSONValue?], context: PropertyContext) -> ColumnTotal {
        let result = Calculations.compute(calculation, values: values, in: context)
        return ColumnTotal(label: label(calculation), value: format(result, calculation, context: context))
    }

    /// Подпись итога в строке под таблицей (Notion «COUNT», «SUM»…).
    public static func label(_ calculation: Calculation) -> String {
        switch calculation {
        case .countAll: "КОЛИЧЕСТВО"
        case .countValues: "ЗНАЧЕНИЙ"
        case .countUnique: "УНИКАЛЬНЫХ"
        case .countEmpty, .percentEmpty: "ПУСТЫХ"
        case .countNotEmpty, .percentNotEmpty: "НЕ ПУСТЫХ"
        case .sum: "СУММА"
        case .average: "СРЕДНЕЕ"
        case .median: "МЕДИАНА"
        case .min: "МИН"
        case .max: "МАКС"
        case .range: "РАЗМАХ"
        case .earliestDate: "РАННЯЯ"
        case .latestDate: "ПОЗДНЯЯ"
        case .dateRange: "ДИАПАЗОН"
        case .checked, .percentChecked: "ОТМЕЧЕНО"
        case .unchecked, .percentUnchecked: "НЕ ОТМЕЧЕНО"
        case .showOriginal, .showUnique: ""
        }
    }

    /// Название пункта в меню «Посчитать ›».
    public static func menuTitle(_ calculation: Calculation) -> String {
        switch calculation {
        case .countAll: "Всего"
        case .countValues: "Значений"
        case .countUnique: "Уникальных значений"
        case .countEmpty, .percentEmpty: "Пустых"
        case .countNotEmpty, .percentNotEmpty: "Не пустых"
        case .sum: "Сумма"
        case .average: "Среднее"
        case .median: "Медиана"
        case .min: "Минимум"
        case .max: "Максимум"
        case .range: "Размах"
        case .earliestDate: "Самая ранняя"
        case .latestDate: "Самая поздняя"
        case .dateRange: "Диапазон дат"
        case .checked: "Отмечено"
        case .unchecked: "Не отмечено"
        case .percentChecked: "Процент отмеченных"
        case .percentUnchecked: "Процент не отмеченных"
        case .showOriginal: "Как есть"
        case .showUnique: "Уникальные значения"
        }
    }

    /// Разделы меню «Посчитать ›» для типа: «Количество ›», «Проценты ›», «Ещё ›» (числа, даты, флажок).
    public static func menuSections(for kind: PropertyKind) -> [(title: String, items: [Calculation])] {
        let available = Set(PropertyTypes.type(for: kind).calculations)
        var sections: [(String, [Calculation])] = [
            ("Количество", [.countAll, .countValues, .countUnique, .countEmpty, .countNotEmpty]),
            ("Проценты", [.percentEmpty, .percentNotEmpty]),
        ]
        let more = (Calculation.numeric + Calculation.dates + Calculation.checkbox).filter(available.contains)
        if !more.isEmpty { sections.append(("Ещё", more)) }
        return sections.map { ($0.0, $0.1.filter(available.contains)) }.filter { !$0.1.isEmpty }
    }

    static func format(_ result: JSONValue?, _ calculation: Calculation, context: PropertyContext) -> String {
        guard let result else { return "—" }
        switch calculation {
        case .percentEmpty, .percentNotEmpty, .percentChecked, .percentUnchecked:
            return percent(result.number ?? 0, locale: context.locale)
        case .sum, .average, .median, .min, .max, .range:
            let number = result.number ?? 0
            if context.property.kind == .number {
                return NumberType.format(number, config: context.config, locale: context.locale)
            }
            return NumberType.format(number, config: ["format": "number"], locale: context.locale)
        case .earliestDate, .latestDate:
            return DateValues.display(result, in: context)
        case .dateRange:
            return days(Int(result.number ?? 0))
        default:
            return NumberType.format(result.number ?? 0, config: ["format": "number"], locale: context.locale)
        }
    }

    static func percent(_ share: Double, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 0
        return (formatter.string(from: NSNumber(value: share * 100)) ?? "\(share * 100)") + "%"
    }

    /// «1 день», «2 дня», «5 дней».
    static func days(_ count: Int) -> String {
        let last = abs(count) % 10, lastTwo = abs(count) % 100
        let word = if last == 1 && lastTwo != 11 { "день" } else if (2...4).contains(last) && !(12...14).contains(lastTwo) { "дня" } else { "дней" }
        return "\(count) \(word)"
    }
}
