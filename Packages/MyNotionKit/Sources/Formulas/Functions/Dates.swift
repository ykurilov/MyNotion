import Foundation

extension FormulaFunctions {
    static let units = ["years", "quarters", "months", "weeks", "days", "hours", "minutes", "seconds", "milliseconds"]

    /// Часть даты числом (`minute`, `hour` …) в поясе календаря.
    private static func part(_ name: String, _ summary: String, _ examples: [FormulaExample],
                             _ body: @escaping @Sendable (Date, Calendar) -> Int) -> FormulaFunctionInfo {
        FormulaFunctionInfo(name, .dates, "\(name)(дата)", summary, examples, typing: Typing.fixed([[.date]], .number),
                            .eager { arguments, evaluator in
                                arguments.date(0).map { .number(Double(body($0.start, evaluator.context.calendar))) } ?? .empty
                            })
    }

    private static func unit(_ arguments: [FormulaValue], _ index: Int) throws -> String {
        guard let unit = arguments.text(index), units.contains(unit) else {
            throw FormulaError("Неизвестная единица „\(arguments.text(index) ?? "")“: years, quarters, months, weeks, days, hours, minutes, seconds, milliseconds")
        }
        return unit
    }

    static let dates: [FormulaFunctionInfo] = [
        FormulaFunctionInfo("now", .dates, "now()", "Текущие дата и время. Формула с now() пересчитывается раз в минуту, пока вид открыт.",
                            [FormulaExample("now()", "@October 21, 2026 5:56 PM")], typing: Typing.fixed([], .date),
                            .eager { _, evaluator in .date(FormulaDate(start: evaluator.context.now, hasTime: true)) }),
        FormulaFunctionInfo("today", .dates, "today()", "Сегодняшняя дата без времени.",
                            [FormulaExample("today()", "@October 21, 2026")], typing: Typing.fixed([], .date),
                            .eager { _, evaluator in
                                .date(FormulaDate(start: evaluator.context.calendar.startOfDay(for: evaluator.context.now), hasTime: false))
                            }),
        part("minute", "Минуты времени: от 0 до 59.", [FormulaExample(#"minute(parseDate("2026-10-21T17:56"))"#, "56")]) { $1.component(.minute, from: $0) },
        part("hour", "Час времени: от 0 до 23.", [FormulaExample(#"hour(parseDate("2026-10-21T17:56"))"#, "17")]) { $1.component(.hour, from: $0) },
        part("day", "День недели: 1 — понедельник, 7 — воскресенье.", [FormulaExample(#"day(parseDate("2026-10-21"))"#, "3"), FormulaExample(#"day(parseDate("2026-10-25"))"#, "7")]) {
            // Как у Notion: 1 — понедельник … 7 — воскресенье (у календаря 1 — воскресенье).
            ($1.component(.weekday, from: $0) + 5) % 7 + 1
        },
        part("date", "Число месяца: от 1 до 31.", [FormulaExample(#"date(parseDate("2026-10-21"))"#, "21")]) { $1.component(.day, from: $0) },
        part("week", "Номер недели года по ISO.", [FormulaExample(#"week(parseDate("2026-10-21"))"#, "43")]) { date, calendar in
            var iso = Calendar(identifier: .iso8601)
            iso.timeZone = calendar.timeZone
            return iso.component(.weekOfYear, from: date)
        },
        part("month", "Месяц: от 1 до 12.", [FormulaExample(#"month(parseDate("2026-10-21"))"#, "10")]) { $1.component(.month, from: $0) },
        part("year", "Год.", [FormulaExample(#"year(parseDate("2026-10-21"))"#, "2026")]) { $1.component(.year, from: $0) },
        FormulaFunctionInfo("dateAdd", .dates, "dateAdd(дата, число, единица)",
                            "Прибавляет к дате число единиц: years, quarters, months, weeks, days, hours, minutes, seconds, milliseconds.",
                            [FormulaExample(#"dateAdd(parseDate("2026-10-21"), 3, "days")"#, "@October 24, 2026")],
                            typing: Typing.fixed([[.date], [.number], [.text]], .date),
                            .eager { arguments, evaluator in try shift(arguments, sign: 1, calendar: evaluator.context.calendar) }),
        FormulaFunctionInfo("dateSubtract", .dates, "dateSubtract(дата, число, единица)", "Вычитает из даты число единиц.",
                            [FormulaExample(#"dateSubtract(parseDate("2026-10-21"), 1, "months")"#, "@September 21, 2026")],
                            typing: Typing.fixed([[.date], [.number], [.text]], .date),
                            .eager { arguments, evaluator in try shift(arguments, sign: -1, calendar: evaluator.context.calendar) }),
        FormulaFunctionInfo("dateBetween", .dates, "dateBetween(дата, дата, единица)",
                            "Сколько целых единиц от второй даты до первой; если первая раньше — с минусом.",
                            [FormulaExample(#"dateBetween(parseDate("2026-10-21"), parseDate("2026-10-01"), "days")"#, "20"),
                             FormulaExample(#"dateBetween(parseDate("2026-01-01"), parseDate("2026-10-01"), "months")"#, "-9")],
                            typing: Typing.fixed([[.date], [.date], [.text]], .number),
                            .eager { arguments, evaluator in
                                guard let first = arguments.date(0), let second = arguments.date(1) else { return .empty }
                                let unit = try unit(arguments, 2)
                                return dateBetween(first.start, second.start, unit: unit, calendar: evaluator.context.calendar).map(FormulaValue.number) ?? .empty
                            }),
        FormulaFunctionInfo("dateRange", .dates, "dateRange(начало, конец)", "Диапазон дат от начала до конца.",
                            [FormulaExample(#"dateRange(parseDate("2026-10-21"), parseDate("2026-10-23"))"#, "@October 21, 2026 → October 23, 2026")],
                            typing: Typing.fixed([[.date], [.date]], .date),
                            .eager { arguments, _ in
                                guard let start = arguments.date(0) else { return .empty }
                                guard let end = arguments.date(1) else { return .date(start) }
                                return .date(FormulaDate(start: start.start, end: end.end ?? end.start, hasTime: start.hasTime || end.hasTime))
                            }),
        FormulaFunctionInfo("dateStart", .dates, "dateStart(дата)", "Начало диапазона; у одной даты — она сама.",
                            [FormulaExample(#"dateStart(dateRange(parseDate("2026-10-21"), parseDate("2026-10-23")))"#, "@October 21, 2026")],
                            typing: Typing.fixed([[.date]], .date),
                            .eager { arguments, _ in arguments.date(0).map { .date(FormulaDate(start: $0.start, hasTime: $0.hasTime)) } ?? .empty }),
        FormulaFunctionInfo("dateEnd", .dates, "dateEnd(дата)", "Конец диапазона; у одной даты — она сама.",
                            [FormulaExample(#"dateEnd(dateRange(parseDate("2026-10-21"), parseDate("2026-10-23")))"#, "@October 23, 2026")],
                            typing: Typing.fixed([[.date]], .date),
                            .eager { arguments, _ in arguments.date(0).map { .date(FormulaDate(start: $0.end ?? $0.start, hasTime: $0.hasTime)) } ?? .empty }),
        FormulaFunctionInfo("timestamp", .dates, "timestamp(дата)", "Миллисекунды с 1 января 1970 года (UTC).",
                            [FormulaExample(#"timestamp(parseDate("2026-10-21T00:00Z"))"#, "1792540800000")],
                            typing: Typing.fixed([[.date]], .number),
                            .eager { arguments, _ in arguments.date(0).map { .number(($0.start.timeIntervalSince1970 * 1_000).rounded()) } ?? .empty }),
        FormulaFunctionInfo("fromTimestamp", .dates, "fromTimestamp(число)", "Дата и время по миллисекундам с 1 января 1970 года (UTC).",
                            [FormulaExample("timestamp(fromTimestamp(1792540800000))", "1792540800000")],
                            typing: Typing.fixed([[.number]], .date),
                            .eager { arguments, _ in
                                arguments.number(0).map { .date(FormulaDate(start: Date(timeIntervalSince1970: $0 / 1_000), hasTime: true)) } ?? .empty
                            }),
        FormulaFunctionInfo("formatDate", .dates, "formatDate(дата, шаблон)",
                            "Дата текстом по шаблону: YYYY год, MM месяц, MMMM название месяца, DD число, dddd день недели, HH:mm время.",
                            [FormulaExample(#"formatDate(parseDate("2026-10-21"), "DD.MM.YYYY")"#, #""21.10.2026""#), FormulaExample(#"formatDate(parseDate("2026-10-21T17:05"), "YYYY-MM-DD HH:mm")"#, #""2026-10-21 17:05""#)],
                            typing: Typing.fixed([[.date], [.text]], .text),
                            .eager { arguments, evaluator in
                                guard let date = arguments.date(0) else { return .text("") }
                                return .text(MomentFormat.format(date.start, pattern: arguments.text(1) ?? "", calendar: evaluator.context.calendar))
                            }),
        FormulaFunctionInfo("parseDate", .dates, "parseDate(текст)", "Дата из текста ISO 8601: 2026-10-21 или 2026-10-21T17:56.",
                            [FormulaExample(#"parseDate("2022-01-01")"#, "@January 1, 2022")],
                            typing: Typing.fixed([[.text]], .date),
                            .eager { arguments, evaluator in
                                guard let text = arguments.text(0), !text.isEmpty else { return .empty }
                                guard let date = parseISO(text, calendar: evaluator.context.calendar) else { throw FormulaError("Не дата: „\(text)“") }
                                return .date(date)
                            }),
    ]

    static func shift(_ arguments: [FormulaValue], sign: Double, calendar: Calendar) throws -> FormulaValue {
        guard let date = arguments.date(0) else { return .empty }
        let unit = try unit(arguments, 2)
        guard let amount = arguments.number(1) else { return .date(date) }
        func moved(_ moment: Date) -> Date {
            let n = amount * sign
            switch unit {
            case "milliseconds": return moment.addingTimeInterval(n / 1_000)
            case "seconds": return moment.addingTimeInterval(n)
            case "minutes": return moment.addingTimeInterval(n * 60)
            case "hours": return moment.addingTimeInterval(n * 3_600)
            default:
                let whole = Int(n.rounded(.towardZero))
                let (component, multiplier): (Calendar.Component, Int) = switch unit {
                case "days": (.day, 1)
                case "weeks": (.day, 7)
                case "months": (.month, 1)
                case "quarters": (.month, 3)
                default: (.year, 1)
                }
                return calendar.date(byAdding: component, value: whole * multiplier, to: moment) ?? moment
            }
        }
        return .date(FormulaDate(start: moved(date.start), end: date.end.map(moved), hasTime: date.hasTime))
    }

    /// Сколько целых единиц от `b` до `a` (как Notion: `dateBetween(a, b, …)` — `a − b`, с усечением к нулю).
    static func dateBetween(_ a: Date, _ b: Date, unit: String, calendar: Calendar) -> Double? {
        let seconds = a.timeIntervalSince(b)
        func truncated(_ value: Double) -> Double { value < 0 ? value.rounded(.up) : value.rounded(.down) }
        switch unit {
        case "milliseconds": return truncated(seconds * 1_000)
        case "seconds": return truncated(seconds)
        case "minutes": return truncated(seconds / 60)
        case "hours": return truncated(seconds / 3_600)
        case "days", "weeks", "months", "quarters", "years":
            let component: Calendar.Component = switch unit {
            case "days": .day
            case "weeks": .weekOfYear
            case "months": .month
            case "quarters": .quarter
            default: .year
            }
            if component == .quarter {
                return calendar.dateComponents([.month], from: b, to: a).month.map { truncated(Double($0) / 3) }
            }
            return calendar.dateComponents([component], from: b, to: a).value(for: component).map(Double.init)
        default: return nil
        }
    }

    /// `2026-10-21`, `2026-10-21T17:56[:05][.123][Z|+03:00]`; без пояса — пояс календаря.
    static func parseISO(_ text: String, calendar: Calendar) -> FormulaDate? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let pattern = #"^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2})(?:\.(\d+))?)?)?\s*(Z|[+-]\d{2}:?\d{2})?$"#
        guard let match = try? RegexCache.shared.regex(pattern).firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) else { return nil }
        func group(_ index: Int) -> String? { Range(match.range(at: index), in: trimmed).map { String(trimmed[$0]) } }
        var components = DateComponents(year: Int(group(1)!), month: Int(group(2)!), day: Int(group(3)!))
        guard (1...12).contains(components.month!), (1...31).contains(components.day!) else { return nil }
        let hasTime = group(4) != nil
        components.hour = group(4).flatMap(Int.init) ?? 0
        components.minute = group(5).flatMap(Int.init) ?? 0
        components.second = group(6).flatMap(Int.init) ?? 0
        var zoned = calendar
        if let zone = group(8) {
            if zone == "Z" { zoned.timeZone = TimeZone(secondsFromGMT: 0)! } else {
                let digits = zone.dropFirst().replacingOccurrences(of: ":", with: "")
                let seconds = (Int(digits.prefix(2))! * 60 + Int(digits.suffix(2))!) * 60
                zoned.timeZone = TimeZone(secondsFromGMT: zone.hasPrefix("-") ? -seconds : seconds)!
            }
        }
        guard var date = zoned.date(from: components) else { return nil }
        if let fraction = group(7) { date.addTimeInterval(Double("0." + fraction) ?? 0) }
        return FormulaDate(start: date, hasTime: hasTime)
    }
}

/// Шаблон `formatDate` как Moment.js у Notion; названия месяцев и дней — на языке календаря (macOS).
enum MomentFormat {
    static let tokens = ["YYYY", "MMMM", "dddd", "MMM", "ddd", "YY", "MM", "Do", "DD", "HH", "hh", "mm", "ss", "Q", "M", "D", "d", "H", "h", "m", "s", "A", "a",
                         "Y"]

    static func format(_ date: Date, pattern: String, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: date)
        let formatter = DateFormatter()
        formatter.locale = calendar.locale ?? .current
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        // Месяц рядом с числом — в родительном падеже («21 октября»), отдельно — в именительном («октябрь»).
        let withDay = pattern.contains("D")
        let months = withDay ? formatter.monthSymbols! : formatter.standaloneMonthSymbols!
        let shortMonths = withDay ? formatter.shortMonthSymbols! : formatter.shortStandaloneMonthSymbols!
        let month = parts.month! - 1, weekday = parts.weekday! - 1, hour = parts.hour!
        func two(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
        var result = ""
        let characters = Array(pattern)
        var index = 0
        while index < characters.count {
            if characters[index] == "[" , let close = characters[index...].firstIndex(of: "]") {
                result += String(characters[(index + 1)..<close])
                index = close + 1
                continue
            }
            let rest = String(characters[index...])
            guard let token = tokens.first(where: { rest.hasPrefix($0) }) else {
                result.append(characters[index])
                index += 1
                continue
            }
            let hour12 = hour % 12 == 0 ? 12 : hour % 12
            let piece = switch token {
            case "YYYY", "Y": String(parts.year!)
            case "YY": two(parts.year! % 100)
            case "Q": String(month / 3 + 1)
            case "MMMM": months[month]
            case "MMM": shortMonths[month]
            case "MM": two(month + 1)
            case "M": String(month + 1)
            case "DD": two(parts.day!)
            case "D": String(parts.day!)
            case "Do": ordinal(parts.day!, locale: formatter.locale)
            case "dddd": formatter.weekdaySymbols[weekday]
            case "ddd": formatter.shortWeekdaySymbols[weekday]
            case "d": String(weekday)
            case "HH": two(hour)
            case "H": String(hour)
            case "hh": two(hour12)
            case "h": String(hour12)
            case "mm": two(parts.minute!)
            case "m": String(parts.minute!)
            case "ss": two(parts.second!)
            case "s": String(parts.second!)
            case "A": hour < 12 ? "AM" : "PM"
            default: hour < 12 ? "am" : "pm"
            }
            result += piece
            index += token.count
        }
        return result
    }

    static func ordinal(_ day: Int, locale: Locale) -> String {
        guard locale.language.languageCode?.identifier == "en" else { return "\(day)-е" }
        let suffix = (11...13).contains(day % 100) ? "th" : (["th", "st", "nd", "rd"] + Array(repeating: "th", count: 6))[day % 10]
        return "\(day)\(suffix)"
    }
}
