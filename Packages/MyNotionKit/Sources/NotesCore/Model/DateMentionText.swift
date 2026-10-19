import Foundation

/// Дата упоминания словами (contracts/blocks-and-keys.md, «Даты и напоминания»): «Сегодня», «Завтра», «Вчера»,
/// иначе «20 октября 2026»; время — «9:00». Дата без времени — день календаря, пояс не важен; дата со временем —
/// момент, и показывается во времени этого Mac.
extension DateMention {
    /// Начало: день и, если есть, время в поясе `timeZone`.
    public var startComponents: DateComponents? {
        let parts = start.split(separator: "T", maxSplits: 1)
        let day = parts.first?.split(separator: "-").compactMap { Int($0) } ?? []
        guard day.count == 3 else { return nil }
        var components = DateComponents(year: day[0], month: day[1], day: day[2])
        if includesTime {
            let time = parts.count > 1 ? parts[1].split(separator: ":").compactMap { Int($0) } : []
            guard time.count >= 2 else { return nil }
            components.hour = time[0]
            components.minute = time[1]
        }
        return components
    }

    /// Момент начала: у даты без времени — полночь этого дня в `timeZone`.
    public var startDate: Date? {
        guard var components = startComponents, let zone = TimeZone(identifier: timeZone) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        components.hour = components.hour ?? 0
        components.minute = components.minute ?? 0
        return calendar.date(from: components)
    }

    /// Начало в записи ISO 8601 без пояса: `2026-10-20` или `2026-10-20T09:00`.
    public static func startText(year: Int, month: Int, day: Int, hour: Int? = nil, minute: Int? = nil) -> String {
        let date = String(format: "%04d-%02d-%02d", year, month, day)
        guard let hour else { return date }
        return date + String(format: "T%02d:%02d", hour, minute ?? 0)
    }

    /// День и время, какими их видит Юрий на этом Mac (`calendar` — его календарь и пояс).
    public func shownComponents(in calendar: Calendar) -> DateComponents? {
        guard includesTime else { return startComponents }
        guard let moment = startDate else { return nil }
        return calendar.dateComponents([.year, .month, .day, .hour, .minute], from: moment)
    }

    /// «Сегодня», «Завтра», «Вчера» относительно `now`, иначе «20 октября 2026».
    public func dayText(now: Date, calendar: Calendar) -> String {
        guard let shown = shownComponents(in: calendar), let year = shown.year, let month = shown.month, let day = shown.day,
              let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return start }
        let today = calendar.startOfDay(for: now)
        switch calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: date)).day {
        case 0: return "Сегодня"
        case 1: return "Завтра"
        case -1: return "Вчера"
        default: return Self.absoluteDayText(year: year, month: month, day: day)
        }
    }

    /// Время «9:00»; у даты без времени — `nil`.
    public func timeText(calendar: Calendar) -> String? {
        guard includesTime, let shown = shownComponents(in: calendar), let hour = shown.hour, let minute = shown.minute else { return nil }
        return String(format: "%d:%02d", hour, minute)
    }

    /// Как дата стоит в тексте страницы: «@Завтра 9:00», «@20 октября 2026».
    public func shownText(now: Date, calendar: Calendar) -> String {
        "@" + [dayText(now: now, calendar: calendar), timeText(calendar: calendar)].compactMap { $0 }.joined(separator: " ")
    }

    /// Без слов «сегодня» и «завтра» — для простого текста, поиска и выгрузки: «20 октября 2026, 9:00».
    public func absoluteText(calendar: Calendar) -> String {
        guard let shown = shownComponents(in: calendar), let year = shown.year, let month = shown.month, let day = shown.day else { return start }
        return [Self.absoluteDayText(year: year, month: month, day: day), timeText(calendar: calendar)].compactMap { $0 }
            .joined(separator: ", ")
    }

    static let genitiveMonths = ["января", "февраля", "марта", "апреля", "мая", "июня", "июля", "августа", "сентября",
                                 "октября", "ноября", "декабря"]

    public static func absoluteDayText(year: Int, month: Int, day: Int) -> String {
        guard (1...12).contains(month) else { return "\(day).\(month).\(year)" }
        return "\(day) \(genitiveMonths[month - 1]) \(year)"
    }
}

extension InlineText {
    /// Простой текст: знак упоминания — название страницы, даты — дата словами, формулы — запись (data-model.md).
    /// `pageTitle` — название по id; `nil` — страница не найдена, вместо названия «Удалённая страница».
    public func plainText(pageTitle: (UUID) -> String?, calendar: Calendar = .current) -> String {
        let atoms = runs.filter { $0.style.isAtom && $0.length == 1 }
        guard !atoms.isEmpty else { return string }
        var units = Array(string.utf16)
        for run in atoms.sorted(by: { $0.start > $1.start }) where run.start < units.count {
            guard units[run.start] == Self.objectReplacementCharacter else { continue }
            let replacement: String = switch run.style {
            case .mention(let pageId): pageTitle(pageId) ?? Self.deletedPageTitle
            case .date(let date): "@" + date.absoluteText(calendar: calendar)
            case .equation(let latex): latex
            default: ""
            }
            units.replaceSubrange(run.start...run.start, with: replacement.utf16)
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// Упоминание страницы из корзины или стёртой (contracts/blocks-and-keys.md, «Упоминания»).
    public static let deletedPageTitle = "Удалённая страница"
}
