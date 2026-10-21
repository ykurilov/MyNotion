import Foundation

/// Значение формулы (contracts/formulas.md, «Значения»).
public indirect enum FormulaValue: Sendable, Hashable {
    case empty
    case number(Double)
    case text(String)
    case bool(Bool)
    case date(FormulaDate)
    case list([FormulaValue])
    /// Строка базы из связи.
    case page(UUID)

    public var number: Double? { if case .number(let value) = self { value } else { nil } }
    public var text: String? { if case .text(let value) = self { value } else { nil } }
    public var date: FormulaDate? { if case .date(let value) = self { value } else { nil } }
    public var list: [FormulaValue]? { if case .list(let value) = self { value } else { nil } }

    /// Флажок: пустое — `false`.
    public var isTrue: Bool {
        switch self {
        case .bool(let value): value
        case .number(let value): value != 0
        case .text(let value): !value.isEmpty
        case .list(let items): !items.isEmpty
        case .date, .page: true
        case .empty: false
        }
    }

    /// Бесконечность и «не число» (корень из отрицательного, ln 0) — пусто, как деление на ноль.
    static func finite(_ value: FormulaValue) -> FormulaValue {
        if case .number(let number) = value, !number.isFinite { return .empty }
        return value
    }

    /// Порядок двух значений одного типа (сравнение, `sort`); разные типы — `nil`.
    static func order(_ left: FormulaValue, _ right: FormulaValue) -> Int? {
        func compare<T: Comparable>(_ a: T, _ b: T) -> Int { a < b ? -1 : (a > b ? 1 : 0) }
        switch (left, right) {
        case (.number(let a), .number(let b)): return compare(a, b)
        case (.text(let a), .text(let b)): return compare(a, b)
        case (.date(let a), .date(let b)): return compare(a.start, b.start)
        case (.bool(let a), .bool(let b)): return compare(a ? 1 : 0, b ? 1 : 0)
        default: return nil
        }
    }
}

/// Дата формулы: момент или диапазон, с временем или без.
public struct FormulaDate: Sendable, Hashable {
    public var start: Date
    public var end: Date?
    public var hasTime: Bool

    public init(start: Date, end: Date? = nil, hasTime: Bool) {
        self.start = start
        self.end = end
        self.hasTime = hasTime
    }
}

/// Откуда формула берёт значения свойств: своя строка и строки из связей.
public protocol FormulaContext {
    /// Значение свойства `propertyId` у строки `rowId`.
    func value(ofProperty propertyId: String, row rowId: UUID) -> FormulaValue
    /// Название страницы из связи (`format`, `join` списка страниц).
    func title(ofPage pageId: UUID) -> String?
    var now: Date { get }
    /// Календарь с поясом и языком macOS (`formatDate`, `day`, `dateBetween`).
    var calendar: Calendar { get }
}

extension FormulaContext {
    public func title(ofPage pageId: UUID) -> String? { nil }
}

/// Значение в текст (`format`, склейка с текстом, итог примера в редакторе).
public enum FormulaText {
    public static func format(_ value: FormulaValue, context: (any FormulaContext)? = nil) -> String {
        switch value {
        case .empty: ""
        case .number(let number): self.number(number)
        case .text(let text): text
        case .bool(let flag): flag ? "true" : "false"
        case .date(let date): self.date(date, timeZone: context?.calendar.timeZone ?? .current)
        case .list(let items): items.map { format($0, context: context) }.joined(separator: ",")
        case .page(let id): context?.title(ofPage: id) ?? id.uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        }
    }

    /// Число как в JavaScript у Notion: целое — без дробной части, иначе кратчайшая запись.
    static func number(_ number: Double) -> String {
        if number == 0 { return "0" }
        if number.rounded() == number, abs(number) < 1e21 { return String(format: "%.0f", number) }
        return "\(number)"
    }

    /// Дата как у Notion: `October 21, 2026`, с временем — `October 21, 2026 5:56 PM`, диапазон — через « → ».
    static func date(_ date: FormulaDate, timeZone: TimeZone) -> String {
        func one(_ moment: Date) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = date.hasTime ? "MMMM d, yyyy h:mm a" : "MMMM d, yyyy"
            return formatter.string(from: moment)
        }
        guard let end = date.end else { return one(date.start) }
        return one(date.start) + " → " + one(end)
    }
}
