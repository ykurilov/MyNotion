extension FormulaFunctions {
    static let logic: [String: FormulaFunction] = [
        "if": .lazy { arguments, evaluator in
            guard arguments.count == 3 else { throw FormulaError("if ждёт три значения: условие, «да», «нет»") }
            return try evaluator.value(of: arguments[0]).isTrue ? try evaluator.value(of: arguments[1]) : try evaluator.value(of: arguments[2])
        },
        "empty": .eager { arguments, _ in
            guard let value = arguments.first else { return .bool(true) }
            return .bool(!value.isTrue && value != .bool(false) || value == .empty)
        },
    ]
}
