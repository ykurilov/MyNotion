import Foundation
import NotesCore

/// Дата: `{start, end?, hasTime, timeZone?, reminder?, relative?}` (data-model.md). `start` — `2026-10-21` или
/// `2026-10-21T15:15` в поясе `timeZone`; `sortNumber` — начало в секундах.
struct DateType: PropertyType {
    let kind = PropertyKind.date
    var filterOperators: [FilterOperator] { FilterOperator.dateOperators }
    var calculations: [Calculation] { Calculation.common + Calculation.dates }

    func comparables(_ value: JSONValue, in context: PropertyContext) -> CellComparables { DateValues.comparables(value) }
    func displayText(_ value: JSONValue?, in context: PropertyContext) -> String { DateValues.display(value, in: context) }
    func csvText(_ value: JSONValue?, in context: PropertyContext) -> String { DateValues.csv(value) }
    func parseCSV(_ text: String, in context: PropertyContext) -> CSVValue { .value(DateValues.parse(text, in: context)) }
    func groupKeys(_ value: JSONValue?, in context: PropertyContext, bucket: JSONValue?) -> [String] {
        DateValues.groupKeys(value, in: context, bucket: bucket?.string ?? "month")
    }
}

/// Создано и изменено: дата-время страницы (`PropertyValue.pageDate`), правки нет.
struct PageTimeType: PropertyType {
    let kind: PropertyKind
    var filterOperators: [FilterOperator] { FilterOperator.dateOperators }
    var calculations: [Calculation] { Calculation.common + Calculation.dates }
    var isEditable: Bool { false }

    func comparables(_ value: JSONValue, in context: PropertyContext) -> CellComparables { DateValues.comparables(value) }
    func displayText(_ value: JSONValue?, in context: PropertyContext) -> String { DateValues.display(value, in: context) }
    func csvText(_ value: JSONValue?, in context: PropertyContext) -> String { DateValues.csv(value) }
    func parseCSV(_ text: String, in context: PropertyContext) -> CSVValue { .value(DateValues.parse(text, in: context)) }
    func groupKeys(_ value: JSONValue?, in context: PropertyContext, bucket: JSONValue?) -> [String] {
        DateValues.groupKeys(value, in: context, bucket: bucket?.string ?? "day")
    }
}

/// Показ, CSV, разбор и группы дат — общие для даты, времени страницы и итогов-дат.
enum DateValues {
    static func start(_ value: JSONValue?) -> Date? {
        value?["start"]?.string.flatMap { DateText.parse($0, timeZone: value?["timeZone"]?.string) }
    }

    static func end(_ value: JSONValue?) -> Date? {
        value?["end"]?.string.flatMap { DateText.parse($0, timeZone: value?["timeZone"]?.string) }
    }

    static func comparables(_ value: JSONValue) -> CellComparables {
        start(value).map { CellComparables(sortNumber: $0.timeIntervalSince1970) } ?? CellComparables()
    }

    private static func zone(_ value: JSONValue?, _ context: PropertyContext) -> TimeZone {
        value?["timeZone"]?.string.flatMap(TimeZone.init(identifier:)) ?? context.calendar.timeZone
    }

    /// Формат даты свойства (contracts/property-types.md, «Дата: форматы»), время — 12 / 24 часа / скрыть.
    static func display(_ value: JSONValue?, in context: PropertyContext) -> String {
        // Дата шаблона строки — «Сегодня» или «Сейчас» (момент создания строки, US6).
        switch value?["relative"]?.string {
        case "today": return "Сегодня"
        case "now": return "Сейчас"
        default: break
        }
        guard let start = start(value) else { return "" }
        let hasTime = value?["hasTime"]?.bool ?? false
        let config = context.config["dateFormat"] == nil && context.config["format"] != nil ? JSONValue.emptyObject : context.config
        func one(_ date: Date) -> String {
            var text = day(date, format: config["dateFormat"]?.string ?? "full", zone: zone(value, context), context: context)
            let timeFormat = config["timeFormat"]?.string ?? "h24"
            if hasTime, timeFormat != "hidden" {
                text += ", " + Formatters.date(context.locale, zone(value, context), pattern: timeFormat == "h12" ? "h:mm a" : "HH:mm").string(from: date)
            }
            return text
        }
        return end(value).map { one(start) + " → " + one($0) } ?? one(start)
    }

    private static func day(_ date: Date, format: String, zone: TimeZone, context: PropertyContext) -> String {
        switch format {
        case "short": return Formatters.date(context.locale, zone, style: .short).string(from: date)
        case "mdy": return Formatters.date(context.locale, zone, pattern: "MM/dd/yyyy").string(from: date)
        case "dmy": return Formatters.date(context.locale, zone, pattern: "dd/MM/yyyy").string(from: date)
        case "ymd": return Formatters.date(context.locale, zone, pattern: "yyyy/MM/dd").string(from: date)
        case "relative":
            var calendar = context.calendar
            calendar.timeZone = zone
            if calendar.isDateInToday(date) { return "Сегодня" }
            if calendar.isDateInYesterday(date) { return "Вчера" }
            if calendar.isDateInTomorrow(date) { return "Завтра" }
            return Formatters.date(context.locale, zone, style: .long).string(from: date)
        default: return Formatters.date(context.locale, zone, style: .long).string(from: date)
        }
    }

    /// Как в CSV Notion: «October 21, 2026», со временем «October 21, 2026 3:15 PM», диапазон «… → …».
    static func csv(_ value: JSONValue?) -> String {
        guard let start = start(value) else { return "" }
        let hasTime = value?["hasTime"]?.bool ?? false
        let formatter = Formatters.date(Locale(identifier: "en_US_POSIX"), value?["timeZone"]?.string.flatMap(TimeZone.init(identifier:)) ?? .current,
                                        pattern: hasTime ? "MMMM d, yyyy h:mm a" : "MMMM d, yyyy")
        return end(value).map { formatter.string(from: start) + " → " + formatter.string(from: $0) } ?? formatter.string(from: start)
    }

    /// Даты Notion и ISO 8601; диапазон «… → …». Не дата — пусто.
    static func parse(_ text: String, in context: PropertyContext) -> JSONValue? {
        let parts = text.components(separatedBy: " → ").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = parts.first, let start = parseOne(first, zone: context.calendar.timeZone) else { return nil }
        var value: JSONValue = ["start": .string(start.text), "hasTime": .bool(start.hasTime), "timeZone": .string(context.calendar.timeZone.identifier)]
        if parts.count > 1, let end = parseOne(parts[1], zone: context.calendar.timeZone) { value["end"] = .string(end.text) }
        return value
    }

    private static func parseOne(_ text: String, zone: TimeZone) -> (text: String, hasTime: Bool)? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        for (format, hasTime) in [("MMMM d, yyyy h:mm a", true), ("MMMM d, yyyy", false), ("yyyy-MM-dd'T'HH:mm", true), ("yyyy-MM-dd", false),
                                  ("yyyy/MM/dd", false)] {
            formatter.dateFormat = format
            guard let date = formatter.date(from: text) else { continue }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            let day = String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
            return (hasTime ? day + String(format: "T%02d:%02d", c.hour!, c.minute!) : day, hasTime)
        }
        return nil
    }

    /// Группы: день, неделя (ISO), месяц, год, «относительно» (сегодня, вчера, завтра, прошлые и следующие 7 и 30 дней).
    static func groupKeys(_ value: JSONValue?, in context: PropertyContext, bucket: String) -> [String] {
        guard let date = start(value) else { return [] }
        var calendar = context.calendar
        calendar.timeZone = zone(value, context)
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        switch bucket {
        case "day": return [String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)]
        case "week":
            var iso = Calendar(identifier: .iso8601)
            iso.timeZone = calendar.timeZone
            let w = iso.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
            return [String(format: "%04d-W%02d", w.yearForWeekOfYear!, w.weekOfYear!)]
        case "year": return [String(c.year!)]
        case "relative":
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: Date()), to: calendar.startOfDay(for: date)).day ?? 0
            switch days {
            case 0: return ["today"]
            case -1: return ["yesterday"]
            case 1: return ["tomorrow"]
            case -7 ..< -1: return ["past7"]
            case 2...7: return ["next7"]
            case -30 ..< -7: return ["past30"]
            case 8...30: return ["next30"]
            default: return [String(format: "%04d-%02d", c.year!, c.month!)]
            }
        default: return [String(format: "%04d-%02d", c.year!, c.month!)]
        }
    }
}

/// Форматтеры дат и чисел — по одному на язык, пояс и шаблон: создание форматтера дороже форматирования, а сетка
/// показывает тысячи значений при прокрутке. `DateFormatter` и `NumberFormatter` потокобезопасны для `string(from:)`.
enum Formatters {
    nonisolated(unsafe) private static var dates: [String: DateFormatter] = [:]
    nonisolated(unsafe) private static var numbers: [String: NumberFormatter] = [:]
    private static let lock = NSLock()

    static func date(_ locale: Locale, _ zone: TimeZone, pattern: String? = nil, style: DateFormatter.Style = .none) -> DateFormatter {
        let key = "\(locale.identifier)|\(zone.identifier)|\(pattern ?? "")|\(style.rawValue)"
        lock.lock()
        defer { lock.unlock() }
        if let formatter = dates[key] { return formatter }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = zone
        if let pattern { formatter.dateFormat = pattern } else { formatter.dateStyle = style }
        dates[key] = formatter
        return formatter
    }

    static func number(_ key: String, make: () -> NumberFormatter) -> NumberFormatter {
        lock.lock()
        defer { lock.unlock() }
        if let formatter = numbers[key] { return formatter }
        let formatter = make()
        numbers[key] = formatter
        return formatter
    }
}
