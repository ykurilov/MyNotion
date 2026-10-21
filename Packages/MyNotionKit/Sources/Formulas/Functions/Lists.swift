extension FormulaFunctions {
    static let lists: [String: FormulaFunction] = [
        "map": .lazy { arguments, evaluator in
            guard arguments.count == 2 else { throw FormulaError("map ждёт список и выражение") }
            guard let items = try evaluator.value(of: arguments[0]).list else { return .list([]) }
            return .list(try items.enumerated().map { index, item in
                try evaluator.with(["current": item, "index": .number(Double(index))]).value(of: arguments[1])
            })
        },
        "length": .eager { arguments, _ in
            switch arguments.first {
            case .list(let items)?: .number(Double(items.count))
            case .text(let text)?: .number(Double(text.count))
            default: .number(0)
            }
        },
    ]
}
