import Foundation
import NotesCore

/// День и время даты без пояса: как они записаны в значении (`2026-10-21T15:15`).
public struct DateParts: Sendable, Hashable, Comparable {
    public var year: Int
    public var month: Int
    public var day: Int
    public var hour: Int
    public var minute: Int

    public init(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0) {
        self.year = year
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = minute
    }

    /// `2026-10-21` или `2026-10-21T15:30`.
    public init?(text: String) {
        let parts = text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard parts.count >= 3 else { return nil }
        self.init(year: parts[0], month: parts[1], day: parts[2], hour: parts.count > 3 ? parts[3] : 0, minute: parts.count > 4 ? parts[4] : 0)
    }

    public init(_ date: Date, calendar: Calendar) {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        self.init(year: c.year!, month: c.month!, day: c.day!, hour: c.hour!, minute: c.minute!)
    }

    public func text(hasTime: Bool) -> String {
        let day = String(format: "%04d-%02d-%02d", year, month, day)
        return hasTime ? day + String(format: "T%02d:%02d", hour, minute) : day
    }

    public func date(in calendar: Calendar) -> Date? {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))
    }

    public var sameDay: DateParts { DateParts(year: year, month: month, day: day) }

    func withDay(of other: DateParts) -> DateParts {
        DateParts(year: other.year, month: other.month, day: other.day, hour: hour, minute: minute)
    }

    public static func < (lhs: DateParts, rhs: DateParts) -> Bool {
        (lhs.year, lhs.month, lhs.day, lhs.hour, lhs.minute) < (rhs.year, rhs.month, rhs.day, rhs.hour, rhs.minute)
    }
}

/// Напоминание ячейки даты (contracts/property-types.md, «Дата: форматы и напоминания»; data-model.md, `reminder`).
public enum DateReminder: String, Sendable, CaseIterable {
    case day0At9, day1, day2, week1, atTime, minutes5, minutes10, minutes15, minutes30, hour1, hour2

    /// Варианты окна «Напомнить» — без времени и со временем, по порядку Notion.
    public static func options(hasTime: Bool) -> [DateReminder] {
        hasTime ? [.atTime, .minutes5, .minutes10, .minutes15, .minutes30, .hour1, .hour2, .day1, .day2] : [.day0At9, .day1, .day2, .week1]
    }

    public func title(hasTime: Bool) -> String {
        switch self {
        case .day0At9: "В день события (9:00)"
        case .day1: hasTime ? "За 1 день" : "За 1 день (9:00)"
        case .day2: hasTime ? "За 2 дня" : "За 2 дня (9:00)"
        case .week1: "За неделю (9:00)"
        case .atTime: "В момент события"
        case .minutes5: "За 5 минут"
        case .minutes10: "За 10 минут"
        case .minutes15: "За 15 минут"
        case .minutes30: "За 30 минут"
        case .hour1: "За 1 час"
        case .hour2: "За 2 часа"
        }
    }

    /// Ближайший вариант после смены «Включить время».
    func adapted(hasTime: Bool) -> DateReminder {
        guard !Self.options(hasTime: hasTime).contains(self) else { return self }
        switch self {
        case .day0At9: return .atTime
        case .week1: return .day2
        default: return hasTime ? .atTime : .day0At9
        }
    }
}

/// Формат даты свойства (data-model.md, `config.dateFormat`).
public enum DateDisplayFormat: String, Sendable, CaseIterable {
    case full, short, mdy, dmy, ymd, relative

    public var title: String {
        switch self {
        case .full: "Полный"
        case .short: "Короткий"
        case .mdy: "Месяц/День/Год"
        case .dmy: "День/Месяц/Год"
        case .ymd: "Год/Месяц/День"
        case .relative: "Относительный"
        }
    }
}

/// Формат времени свойства (data-model.md, `config.timeFormat`).
public enum TimeDisplayFormat: String, Sendable, CaseIterable {
    case h12, h24, hidden

    public var title: String {
        switch self {
        case .h12: "12 часов"
        case .h24: "24 часа"
        case .hidden: "Скрыть"
        }
    }
}

/// Значение ячейки даты в окне правки (spec US2, сценарий 4): начало, конец, время, напоминание. Ключи, которых окно
/// не знает (`relative` шаблона и от новых версий), сохраняются.
public struct DateCellValue: Sendable, Hashable {
    public var start: DateParts
    public var end: DateParts?
    public var hasTime: Bool
    public var timeZone: String
    public var reminder: DateReminder?
    private var extra: [String: JSONValue] = [:]

    public init(day: DateParts, timeZone: String) {
        start = day.sameDay
        hasTime = false
        self.timeZone = timeZone
    }

    public init?(json: JSONValue?) {
        guard let json, let start = json["start"]?.string.flatMap(DateParts.init(text:)) else { return nil }
        self.start = start
        end = json["end"]?.string.flatMap(DateParts.init(text:))
        hasTime = json["hasTime"]?.bool ?? false
        timeZone = json["timeZone"]?.string ?? TimeZone.current.identifier
        reminder = json["reminder"]?.string.flatMap(DateReminder.init(rawValue:))
        if case .object(let all) = json {
            extra = all.filter { !["start", "end", "hasTime", "timeZone", "reminder"].contains($0.key) }
        }
        if let raw = json["reminder"]?.string, reminder == nil { extra["reminder"] = .string(raw) }
    }

    public var json: JSONValue {
        var object = extra
        object["start"] = .string(start.text(hasTime: hasTime))
        if let end { object["end"] = .string(end.text(hasTime: hasTime)) }
        object["hasTime"] = .bool(hasTime)
        object["timeZone"] = .string(timeZone)
        if let reminder { object["reminder"] = .string(reminder.rawValue) }
        return .object(object)
    }

    /// «Сегодня» или «Сейчас» шаблона строки (US6, «Быстрый выбор»): `today`, `now`; `nil` — обычная дата.
    public var templateRelative: String? {
        get { extra["relative"]?.string }
        set { extra["relative"] = newValue.map(JSONValue.string) }
    }

    /// «Дата окончания»: конец — как начало; выключить — конца нет.
    public mutating func setHasEnd(_ on: Bool) {
        end = on ? (end ?? start) : nil
    }

    /// «Включить время»: текущее время (как у Notion), `now` — часы и минуты сейчас в поясе значения; напоминание
    /// переходит на ближайшее из нового списка.
    public mutating func setHasTime(_ on: Bool, now: (hour: Int, minute: Int)? = nil) {
        guard on != hasTime else { return }
        hasTime = on
        if on {
            let time = now ?? currentTime
            start.hour = time.hour
            start.minute = time.minute
            end?.hour = time.hour
            end?.minute = time.minute
        } else {
            start = start.sameDay
            end = end?.sameDay
        }
        reminder = reminder?.adapted(hasTime: on)
    }

    /// Часы и минуты сейчас в поясе значения.
    var currentTime: (hour: Int, minute: Int) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone) ?? .current
        let parts = calendar.dateComponents([.hour, .minute], from: Date())
        return (parts.hour ?? 0, parts.minute ?? 0)
    }

    public mutating func setTime(hour: Int, minute: Int, forEnd: Bool) {
        hasTime = true
        if forEnd {
            end?.hour = hour
            end?.minute = minute
        } else {
            start.hour = hour
            start.minute = minute
        }
        orderEnds()
    }

    /// Щелчок по дню календаря: день начала или конца, время прежнее.
    public mutating func pick(_ day: DateParts, editingEnd: Bool) {
        if editingEnd, let current = end {
            end = current.withDay(of: day)
        } else {
            start = start.withDay(of: day)
        }
        orderEnds()
    }

    /// Ввод в поле даты окна: «21.10.2026», «21.10.2026 15:15», «21 октября 2026», «October 21, 2026», ISO. Без
    /// времени в тексте — время прежнее. `false` — не дата.
    @discardableResult
    public mutating func type(_ text: String, forEnd: Bool) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let (parts, withTime) = Self.parse(trimmed, timeZone: timeZone) else { return false }
        var target = (forEnd ? end : start) ?? start
        target = target.withDay(of: parts)
        if withTime {
            target.hour = parts.hour
            target.minute = parts.minute
            hasTime = true
            reminder = reminder?.adapted(hasTime: true)
        }
        if forEnd, end != nil { end = target } else { start = target }
        orderEnds()
        return true
    }

    private static let typedFormats: [(String, String, Bool)] = [
        ("dd.MM.yyyy HH:mm", "en_US_POSIX", true), ("dd.MM.yyyy", "en_US_POSIX", false),
        ("d MMMM yyyy HH:mm", "ru_RU", true), ("d MMMM yyyy", "ru_RU", false),
        ("MMMM d, yyyy h:mm a", "en_US_POSIX", true), ("MMMM d, yyyy", "en_US_POSIX", false),
        ("yyyy-MM-dd'T'HH:mm", "en_US_POSIX", true), ("yyyy-MM-dd", "en_US_POSIX", false),
    ]

    static func parse(_ text: String, timeZone: String) -> (DateParts, Bool)? {
        let zone = TimeZone(identifier: timeZone) ?? .current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let formatter = DateFormatter()
        formatter.timeZone = zone
        formatter.isLenient = false
        for (format, locale, withTime) in typedFormats {
            formatter.locale = Locale(identifier: locale)
            formatter.dateFormat = format
            guard let date = formatter.date(from: text) else { continue }
            return (DateParts(date, calendar: calendar), withTime)
        }
        return nil
    }

    /// Конец раньше начала — меняются местами.
    private mutating func orderEnds() {
        guard let current = end, current < start else { return }
        end = start
        start = current
    }
}

/// Календарь окна даты: шесть недель с первого дня недели календаря (у Юрия — понедельник).
public enum MonthGrid {
    public static func days(year: Int, month: Int, calendar: Calendar) -> [DateParts] {
        guard let first = calendar.date(from: DateComponents(year: year, month: month, day: 1)) else { return [] }
        let weekday = calendar.component(.weekday, from: first)
        let offset = (weekday - calendar.firstWeekday + 7) % 7
        return (0..<42).compactMap { index in
            calendar.date(byAdding: .day, value: index - offset, to: first).map { DateParts($0, calendar: calendar).sameDay }
        }
    }

    /// «Пн», «Вт»… с первого дня недели.
    public static func weekdaySymbols(calendar: Calendar, locale: Locale) -> [String] {
        var localized = calendar
        localized.locale = locale
        let symbols = localized.shortStandaloneWeekdaySymbols
        let start = calendar.firstWeekday - 1
        return (0..<7).map { symbols[(start + $0) % 7].capitalized(with: locale).replacingOccurrences(of: ".", with: "") }
    }

    /// «Октябрь 2026».
    public static func title(year: Int, month: Int, locale: Locale) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        return calendar.standaloneMonthSymbols[month - 1].capitalized(with: locale) + " \(year)"
    }
}
