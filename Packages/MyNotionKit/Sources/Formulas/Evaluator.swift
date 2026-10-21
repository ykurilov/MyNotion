import Foundation

/// Вычисление формулы для строки (research R6). Ошибка вычисления в строке — пустой итог (contracts/formulas.md, «Итог»).
public struct FormulaEvaluator {
    public let context: any FormulaContext
    public let rowId: UUID
    var scope: [String: FormulaValue] = [:]

    public init(context: any FormulaContext, rowId: UUID) {
        self.context = context
        self.rowId = rowId
    }

    /// Итог для строки; ошибка — пусто.
    public static func evaluate(_ expression: FormulaExpression, row rowId: UUID, context: any FormulaContext) -> FormulaValue {
        (try? FormulaEvaluator(context: context, rowId: rowId).value(of: expression)) ?? .empty
    }

    public func value(of expression: FormulaExpression) throws -> FormulaValue {
        switch expression.kind {
        case .number(let value): return .number(value)
        case .text(let value): return .text(value)
        case .bool(let value): return .bool(value)
        case .list(let items): return .list(try items.map(value(of:)))
        case .name(let name):
            if let bound = scope[name] { return bound }
            throw FormulaError("Неизвестное имя „\(name)“", at: expression.range)
        case .unary(let op, let operand): return try FormulaOperators.unary(op, try value(of: operand))
        case .binary("and", let left, let right):
            return .bool(try value(of: left).isTrue ? try value(of: right).isTrue : false)
        case .binary("or", let left, let right):
            return .bool(try value(of: left).isTrue ? true : try value(of: right).isTrue)
        case .binary(let op, let left, let right): return try FormulaOperators.binary(op, try value(of: left), try value(of: right))
        case .conditional(let condition, let yes, let no): return try value(of: condition).isTrue ? try value(of: yes) : try value(of: no)
        case .call(let name, let arguments):
            guard let function = FormulaFunctionCatalog.byName[name] else {
                throw FormulaError("Функция \(name) не поддерживается в MyNotion", at: expression.range)
            }
            do {
                switch function.body {
                case .eager(let body): return FormulaValue.finite(try body(try arguments.map(value(of:)), self))
                case .lazy(let body): return FormulaValue.finite(try body(arguments, self))
                }
            } catch let error as FormulaError where error.range == nil {
                throw FormulaError(error.message, at: expression.range)
            }
        }
    }

    /// То же с привязанными `current` и `index` (map, filter …) или переменными `let`.
    func with(_ bindings: [String: FormulaValue]) -> FormulaEvaluator {
        var copy = self
        copy.scope.merge(bindings) { $1 }
        return copy
    }
}

/// Операторы: `+` складывает числа и склеивает текст, пустое в арифметике — пусто.
enum FormulaOperators {
    static func unary(_ op: String, _ value: FormulaValue) throws -> FormulaValue {
        switch op {
        case "not": return .bool(!value.isTrue)
        case "-": return value.number.map { .number(-$0) } ?? .empty
        default: throw FormulaError("Неизвестный знак „\(op)“")
        }
    }

    static func binary(_ op: String, _ left: FormulaValue, _ right: FormulaValue) throws -> FormulaValue {
        switch op {
        case "+":
            if let a = left.number, let b = right.number { return .number(a + b) }
            if left.text != nil || right.text != nil { return .text(FormulaText.format(left) + FormulaText.format(right)) }
            return .empty
        case "-", "*", "/", "%", "^":
            guard let a = left.number, let b = right.number else { return .empty }
            return FormulaValue.finite(arithmetic(op, a, b))
        case "==": return .bool(left == right)
        case "!=": return .bool(left != right)
        case ">", ">=", "<", "<=":
            guard let order = FormulaValue.order(left, right) else { return .bool(false) }
            switch op {
            case ">": return .bool(order > 0)
            case ">=": return .bool(order >= 0)
            case "<": return .bool(order < 0)
            default: return .bool(order <= 0)
            }
        default: throw FormulaError("Неизвестный знак „\(op)“")
        }
    }

    static func arithmetic(_ op: String, _ a: Double, _ b: Double) -> FormulaValue {
        switch op {
        case "-": .number(a - b)
        case "*": .number(a * b)
        case "/": b == 0 ? .empty : .number(a / b)
        case "%": b == 0 ? .empty : .number(a.truncatingRemainder(dividingBy: b))
        default: .number(pow(a, b))
        }
    }
}
