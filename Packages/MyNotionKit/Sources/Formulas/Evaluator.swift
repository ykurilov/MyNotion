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
        switch expression {
        case .number(let value): return .number(value)
        case .text(let value): return .text(value)
        case .bool(let value): return .bool(value)
        case .list(let items): return .list(try items.map(value(of:)))
        case .name(let name):
            if let bound = scope[name] { return bound }
            throw FormulaError("Нет переменной «\(name)»")
        case .unary(let op, let operand): return try FormulaOperators.unary(op, try value(of: operand))
        case .binary("and", let left, let right):
            return .bool(try value(of: left).isTrue ? try value(of: right).isTrue : false)
        case .binary("or", let left, let right):
            return .bool(try value(of: left).isTrue ? true : try value(of: right).isTrue)
        case .binary(let op, let left, let right): return try FormulaOperators.binary(op, try value(of: left), try value(of: right))
        case .conditional(let condition, let yes, let no): return try value(of: condition).isTrue ? try value(of: yes) : try value(of: no)
        case .call(let name, let arguments):
            guard let function = FormulaFunctionCatalog.functions[name] else {
                throw FormulaError("Функция \(name) не поддерживается в MyNotion")
            }
            switch function {
            case .eager(let body): return try body(try arguments.map(value(of:)), self)
            case .lazy(let body): return try body(arguments, self)
            }
        }
    }

    /// То же с привязанными `current` и `index` (map, filter …).
    func with(_ bindings: [String: FormulaValue]) -> FormulaEvaluator {
        var copy = self
        copy.scope.merge(bindings) { $1 }
        return copy
    }
}

/// Функция формулы: со значениями аргументов или с самими выражениями (`if`, `map` — вычисляют выборочно).
public enum FormulaFunction: Sendable {
    case eager(@Sendable ([FormulaValue], FormulaEvaluator) throws -> FormulaValue)
    case lazy(@Sendable ([FormulaExpression], FormulaEvaluator) throws -> FormulaValue)
}

/// Все функции по разделам (contracts/formulas.md, «Функции»): каждый раздел — свой файл в `Functions/`.
public enum FormulaFunctionCatalog {
    public static let functions: [String: FormulaFunction] = [FormulaFunctions.pages, FormulaFunctions.logic, FormulaFunctions.dates,
                                                              FormulaFunctions.lists]
        .reduce(into: [:]) { $0.merge($1) { first, _ in first } }
}

/// Разделы функций — расширения в `Functions/`.
public enum FormulaFunctions {}

/// Операторы: `+` складывает числа и склеивает текст, пустое в арифметике — пусто.
enum FormulaOperators {
    static func unary(_ op: String, _ value: FormulaValue) throws -> FormulaValue {
        switch op {
        case "not": return .bool(!value.isTrue)
        case "-": return value.number.map { .number(-$0) } ?? .empty
        default: throw FormulaError("Неизвестный знак «\(op)»")
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
            switch op {
            case "-": return .number(a - b)
            case "*": return .number(a * b)
            case "/": return b == 0 ? .empty : .number(a / b)
            case "%": return b == 0 ? .empty : .number(a.truncatingRemainder(dividingBy: b))
            default: return .number(pow(a, b))
            }
        case "==": return .bool(left == right)
        case "!=": return .bool(left != right)
        case ">", ">=", "<", "<=":
            let order: Int
            if let a = left.number, let b = right.number { order = a < b ? -1 : (a > b ? 1 : 0) }
            else if let a = left.text, let b = right.text { order = a < b ? -1 : (a > b ? 1 : 0) }
            else if let a = left.date?.start, let b = right.date?.start { order = a < b ? -1 : (a > b ? 1 : 0) }
            else { return .bool(false) }
            switch op {
            case ">": return .bool(order > 0)
            case ">=": return .bool(order >= 0)
            case "<": return .bool(order < 0)
            default: return .bool(order <= 0)
            }
        default: throw FormulaError("Неизвестный знак «\(op)»")
        }
    }
}

/// Значение в текст (`format`, склейка).
enum FormulaText {
    static func format(_ value: FormulaValue) -> String {
        switch value {
        case .empty: ""
        case .number(let number): number.rounded() == number && abs(number) < 1e15 ? String(Int64(number)) : String(number)
        case .text(let text): text
        case .bool(let flag): flag ? "true" : "false"
        case .date(let date): date.start.formatted(date: .long, time: date.hasTime ? .shortened : .omitted)
        case .list(let items): items.map(format).joined(separator: ",")
        case .page(let id): id.uuidString
        }
    }
}
