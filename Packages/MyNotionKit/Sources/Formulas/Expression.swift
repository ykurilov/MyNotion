/// Дерево формулы. Вызов методом сводится к вызову функцией: `x.f(a)` — это `f(x, a)` (contracts/formulas.md).
public indirect enum FormulaExpression: Sendable, Hashable {
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

    /// Свойства, от которых зависит формула: `prop("…")` своей строки и `current.prop("…")` связанных
    /// (граф пересчёта, research R6).
    public var referencedProperties: Set<String> {
        var result: Set<String> = []
        func visit(_ expression: FormulaExpression) {
            switch expression {
            case .call(let name, let arguments):
                if name == "prop", let last = arguments.last, case .text(let id) = last { result.insert(id) }
                arguments.forEach(visit)
            case .list(let items): items.forEach(visit)
            case .unary(_, let operand): visit(operand)
            case .binary(_, let left, let right): visit(left); visit(right)
            case .conditional(let condition, let yes, let no): visit(condition); visit(yes); visit(no)
            default: break
            }
        }
        visit(self)
        return result
    }

    /// Формула «живая» — с `now()` или `today()` (FR-323).
    public var isLive: Bool {
        switch self {
        case .call(let name, let arguments): name == "now" || name == "today" || arguments.contains(where: \.isLive)
        case .list(let items): items.contains(where: \.isLive)
        case .unary(_, let operand): operand.isLive
        case .binary(_, let left, let right): left.isLive || right.isLive
        case .conditional(let condition, let yes, let no): condition.isLive || yes.isLive || no.isLive
        default: false
        }
    }
}
