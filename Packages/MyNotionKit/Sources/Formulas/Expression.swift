/// Дерево формулы с местом каждого узла в тексте (для ошибок с подчёркиванием). Вызов методом сводится к вызову
/// функцией: `x.f(a)` — это `f(x, a)` (contracts/formulas.md). Равенство узлов место не учитывает.
public struct FormulaExpression: Sendable, Hashable {
    public indirect enum Kind: Sendable, Hashable {
        case number(Double)
        case text(String)
        case bool(Bool)
        case list([FormulaExpression])
        /// Имя: `current`, `index`, переменная `let`.
        case name(String)
        case call(String, [FormulaExpression])
        case unary(String, FormulaExpression)
        case binary(String, FormulaExpression, FormulaExpression)
        case conditional(FormulaExpression, FormulaExpression, FormulaExpression)
    }

    public var kind: Kind
    /// Место в тексте (смещения в символах Swift).
    public var range: Range<Int>

    public init(_ kind: Kind, range: Range<Int> = 0..<0) {
        self.kind = kind
        self.range = range
    }

    public static func == (lhs: FormulaExpression, rhs: FormulaExpression) -> Bool { lhs.kind == rhs.kind }
    public func hash(into hasher: inout Hasher) { hasher.combine(kind) }

    public static func number(_ value: Double) -> FormulaExpression { FormulaExpression(.number(value)) }
    public static func text(_ value: String) -> FormulaExpression { FormulaExpression(.text(value)) }
    public static func bool(_ value: Bool) -> FormulaExpression { FormulaExpression(.bool(value)) }
    public static func list(_ items: [FormulaExpression]) -> FormulaExpression { FormulaExpression(.list(items)) }
    public static func name(_ name: String) -> FormulaExpression { FormulaExpression(.name(name)) }
    public static func call(_ name: String, _ arguments: [FormulaExpression]) -> FormulaExpression { FormulaExpression(.call(name, arguments)) }
    public static func unary(_ op: String, _ operand: FormulaExpression) -> FormulaExpression { FormulaExpression(.unary(op, operand)) }
    public static func binary(_ op: String, _ left: FormulaExpression, _ right: FormulaExpression) -> FormulaExpression {
        FormulaExpression(.binary(op, left, right))
    }
    public static func conditional(_ condition: FormulaExpression, _ yes: FormulaExpression, _ no: FormulaExpression) -> FormulaExpression {
        FormulaExpression(.conditional(condition, yes, no))
    }

    /// Прямые потомки узла.
    public var children: [FormulaExpression] {
        switch kind {
        case .list(let items): items
        case .call(_, let arguments): arguments
        case .unary(_, let operand): [operand]
        case .binary(_, let left, let right): [left, right]
        case .conditional(let condition, let yes, let no): [condition, yes, no]
        default: []
        }
    }

    /// Свойства, от которых зависит формула: `prop("…")` своей строки и `current.prop("…")` связанных
    /// (граф пересчёта, research R6).
    public var referencedProperties: Set<String> {
        var result: Set<String> = []
        func visit(_ expression: FormulaExpression) {
            if case .call("prop", let arguments) = expression.kind, let last = arguments.last, case .text(let id) = last.kind { result.insert(id) }
            expression.children.forEach(visit)
        }
        visit(self)
        return result
    }

    /// Формула «живая» — с `now()` или `today()` (FR-323).
    public var isLive: Bool {
        if case .call(let name, _) = kind, name == "now" || name == "today" { return true }
        return children.contains(where: \.isLive)
    }
}
