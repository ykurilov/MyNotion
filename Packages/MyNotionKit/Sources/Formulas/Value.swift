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
    var now: Date { get }
    var calendar: Calendar { get }
}
