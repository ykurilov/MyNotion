import Foundation
import NotesCore

/// Дата по набору после «@» (contracts/blocks-and-keys.md, «Даты и напоминания»): «сегодня», «завтра», «вчера»,
/// «через неделю», «25 окт», «25.10», «25.10.2026», «25 октября 14:30». Дата — в поясе этого Mac (research R12).
enum DateQuery {
    struct Suggestion: Equatable {
        var title: String
        var mention: DateMention
    }

    /// Слова окна «@»: название и сдвиг в днях от сегодня; по каждому слову и его синонимам ищется начало.
    private static let words: [(title: String, days: Int, keywords: [String])] = [
        ("Сегодня", 0, ["сегодня", "today"]),
        ("Завтра", 1, ["завтра", "tomorrow"]),
        ("Вчера", -1, ["вчера", "yesterday"]),
        ("Через неделю", 7, ["через неделю", "next week", "неделя"]),
    ]

    /// Подсказки окна «@»: набранная дата — первой, затем слова, чьё начало совпало с набором. Каждая — новая дата.
    static func suggestions(for query: String, now: Date, calendar: Calendar) -> [Suggestion] {
        let typed = normalized(query)
        var result: [Suggestion] = []
        if let mention = parse(typed, now: now, calendar: calendar), !words.contains(where: { $0.keywords.contains(typed) }) {
            result.append(Suggestion(title: mention.titleInPicker(calendar: calendar), mention: mention))
        }
        for word in words where typed.isEmpty || word.keywords.contains(where: { $0.hasPrefix(typed) }) {
            guard let mention = day(offset: word.days, now: now, calendar: calendar) else { continue }
            result.append(Suggestion(title: word.title, mention: mention))
        }
        return result
    }

    /// Дата из набора или `nil`.
    static func parse(_ query: String, now: Date, calendar: Calendar) -> DateMention? {
        let typed = normalized(query)
        guard !typed.isEmpty else { return nil }
        if let word = words.first(where: { $0.keywords.contains(typed) }) {
            return day(offset: word.days, now: now, calendar: calendar)
        }
        var parts = typed.split(separator: " ").map(String.init)
        var time: (hour: Int, minute: Int)?
        if let last = parts.last, last.contains(":") {
            let pieces = last.split(separator: ":").compactMap { Int($0) }
            guard pieces.count == 2, (0...23).contains(pieces[0]), (0...59).contains(pieces[1]) else { return nil }
            time = (pieces[0], pieces[1])
            parts.removeLast()
        }
        let year = calendar.component(.year, from: now)
        let date: (year: Int, month: Int, day: Int)
        switch parts.count {
        case 1 where parts[0].contains("."):
            let pieces = parts[0].split(separator: ".").map(String.init)
            guard (2...3).contains(pieces.count), let day = Int(pieces[0]), let month = Int(pieces[1]) else { return nil }
            var fullYear = year
            if pieces.count == 3 {
                guard let typedYear = Int(pieces[2]) else { return nil }
                fullYear = typedYear < 100 ? 2000 + typedYear : typedYear
            }
            date = (fullYear, month, day)
        case 2, 3:
            guard let day = Int(parts[0]), let month = month(named: parts[1]) else { return nil }
            var fullYear = year
            if parts.count == 3 {
                guard let typedYear = Int(parts[2]) else { return nil }
                fullYear = typedYear
            }
            date = (fullYear, month, day)
        default:
            return nil
        }
        guard isValid(date, calendar: calendar) else { return nil }
        return DateMention(start: DateMention.startText(year: date.year, month: date.month, day: date.day,
                                                        hour: time?.hour, minute: time?.minute),
                           includesTime: time != nil, timeZone: calendar.timeZone.identifier)
    }

    /// Набор может стать датой, если дописать: «25», «25.», «25 о», «25.10.2026 9:».
    static func mayBecomeDate(_ query: String) -> Bool {
        let typed = normalized(query)
        guard let first = typed.first, first.isNumber else { return false }
        return typed.allSatisfy { $0.isNumber || $0.isLetter || $0 == "." || $0 == ":" || $0 == " " }
    }

    private static func normalized(_ query: String) -> String {
        query.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func day(offset: Int, now: Date, calendar: Calendar) -> DateMention? {
        guard let date = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)) else { return nil }
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        return DateMention(start: DateMention.startText(year: year, month: month, day: day), includesTime: false,
                           timeZone: calendar.timeZone.identifier)
    }

    /// Месяц по началу названия: «окт», «октября», «oct».
    private static func month(named name: String) -> Int? {
        let stems = ["янв", "фев", "мар", "апр", "ма", "июн", "июл", "авг", "сен", "окт", "ноя", "дек"]
        let english = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        guard name.count >= 2 else { return nil }
        if let index = english.firstIndex(where: { name.hasPrefix($0) }) { return index + 1 }
        // «ма» — и март, и май: «мар…» проверяется раньше.
        if name.hasPrefix("мар") { return 3 }
        if name.hasPrefix("ма") { return 5 }
        return stems.firstIndex(where: { name.hasPrefix($0) || ($0.hasPrefix(name) && name.count >= 3) }).map { $0 + 1 }
    }

    private static func isValid(_ date: (year: Int, month: Int, day: Int), calendar: Calendar) -> Bool {
        let components = DateComponents(year: date.year, month: date.month, day: date.day)
        guard (1...12).contains(date.month), (1...31).contains(date.day), let real = calendar.date(from: components) else { return false }
        return calendar.component(.day, from: real) == date.day
    }
}

extension DateMention {
    /// Строка окна «@» для набранной даты: «25 октября 2026 14:30».
    func titleInPicker(calendar: Calendar) -> String {
        absoluteText(calendar: calendar).replacingOccurrences(of: ", ", with: " ")
    }
}

/// «Напомнить» в календарике (contracts/blocks-and-keys.md): «Нет», «В момент события», «За 5 минут», «За 1 час»,
/// «За 1 день (9:00)». У дня без времени событие — в 9:00 этого дня в поясе даты.
enum ReminderChoice: CaseIterable, Equatable {
    case none, atEvent, fiveMinutesBefore, hourBefore, dayBefore

    var title: String {
        switch self {
        case .none: "Нет"
        case .atEvent: "В момент события"
        case .fiveMinutesBefore: "За 5 минут"
        case .hourBefore: "За 1 час"
        case .dayBefore: "За 1 день (9:00)"
        }
    }

    static let dayStartHour = 9

    func fireAt(for date: DateMention) -> Date? {
        guard self != .none, let zone = TimeZone(identifier: date.timeZone), var components = date.startComponents else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        if !date.includesTime {
            components.hour = Self.dayStartHour
            components.minute = 0
        }
        guard let event = calendar.date(from: components) else { return nil }
        switch self {
        case .none: return nil
        case .atEvent: return event
        case .fiveMinutesBefore: return event.addingTimeInterval(-5 * 60)
        case .hourBefore: return event.addingTimeInterval(-60 * 60)
        case .dayBefore:
            guard let previous = calendar.date(byAdding: .day, value: -1, to: event) else { return nil }
            return calendar.date(bySettingHour: Self.dayStartHour, minute: 0, second: 0, of: previous)
        }
    }

    /// Какой выбор стоит у даты сейчас; напоминание на другой момент считается «В момент события».
    static func current(for date: DateMention) -> ReminderChoice {
        guard let fireAt = date.reminder?.fireAt else { return .none }
        return allCases.first { $0 != .none && $0.fireAt(for: date) == fireAt } ?? .atEvent
    }
}
