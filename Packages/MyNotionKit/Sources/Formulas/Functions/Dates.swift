import Foundation

extension FormulaFunctions {
    static let dates: [String: FormulaFunction] = [
        "now": .eager { _, evaluator in .date(FormulaDate(start: evaluator.context.now, hasTime: true)) },
        "today": .eager { _, evaluator in .date(FormulaDate(start: evaluator.context.calendar.startOfDay(for: evaluator.context.now), hasTime: false)) },
        "dateBetween": .eager { arguments, evaluator in
            guard arguments.count == 3 else { throw FormulaError("dateBetween ждёт две даты и единицу") }
            guard let first = arguments[0].date, let second = arguments[1].date else { return .empty }
            guard let unit = arguments[2].text else { throw FormulaError("dateBetween ждёт единицу текстом") }
            return dateBetween(first.start, second.start, unit: unit, calendar: evaluator.context.calendar).map(FormulaValue.number) ?? .empty
        },
    ]

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
}
