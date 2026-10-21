import Foundation

extension FormulaFunctions {
    /// `prop("id")` своей строки и `страница.prop("id")` строки из связи. Типы `prop` проверяет `FormulaTypeChecker` по схеме.
    static let pages: [FormulaFunctionInfo] = [
        FormulaFunctionInfo("prop", .pages, "prop(\"Свойство\")", "Значение свойства этой строки; у страницы из связи — её свойства: current.prop(\"Название\").",
                            [], typing: { _ in .any },
                            .eager { arguments, evaluator in
                                switch arguments.count {
                                case 1:
                                    guard let id = arguments[0].text else { throw FormulaError("prop ждёт название свойства") }
                                    return evaluator.context.value(ofProperty: id, row: evaluator.rowId)
                                case 2:
                                    guard case .page(let row) = arguments[0], let id = arguments[1].text else { return .empty }
                                    return evaluator.context.value(ofProperty: id, row: row)
                                default: throw FormulaError("prop ждёт одно название свойства")
                                }
                            }),
        FormulaFunctionInfo("id", .pages, "id(страница?)", "Id этой строки или страницы из связи — текстом.",
                            [FormulaExample("length(id())", "32")],
                            typing: { call in
                                try call.arity(0...1)
                                if call.count == 1 { try call.expect(0, .page(database: nil)) }
                                return .text
                            },
                            .eager { arguments, evaluator in
                                if case .page(let row)? = arguments.first { return .text(compactId(row)) }
                                return .text(compactId(evaluator.rowId))
                            }),
        FormulaFunctionInfo("let", .pages, "let(имя, значение, выражение)", "Переменная: имя получает значение, выражение его использует.",
                            [FormulaExample("let(x, 5, x * 2)", "10")],
                            typing: { call in
                                try call.arity(3...3)
                                let name = try variable(call.arguments[0])
                                return try call.type(2, with: [name: try call.type(1)])
                            },
                            .lazy { arguments, evaluator in
                                try evaluator.with([try variable(arguments[0]): try evaluator.value(of: arguments[1])]).value(of: arguments[2])
                            }),
        FormulaFunctionInfo("lets", .pages, "lets(имя, значение, имя2, значение2, …, выражение)", "Несколько переменных подряд; следующая видит предыдущие.",
                            [FormulaExample("lets(a, 2, b, a + 3, a * b)", "10")],
                            typing: { call in
                                try call.arity(3...Int.max)
                                guard call.count % 2 == 1 else { throw FormulaError("Функция lets ждёт пары «имя, значение» и выражение в конце", at: call.range) }
                                var bindings: [String: FormulaType] = [:]
                                for index in stride(from: 0, to: call.count - 1, by: 2) {
                                    bindings[try variable(call.arguments[index])] = try call.type(index + 1, with: bindings)
                                }
                                return try call.type(call.count - 1, with: bindings)
                            },
                            .lazy { arguments, evaluator in
                                var scoped = evaluator
                                for index in stride(from: 0, to: arguments.count - 1, by: 2) {
                                    scoped = scoped.with([try variable(arguments[index]): try scoped.value(of: arguments[index + 1])])
                                }
                                return try scoped.value(of: arguments[arguments.count - 1])
                            }),
    ]

    static func compactId(_ id: UUID) -> String { id.uuidString.lowercased().replacingOccurrences(of: "-", with: "") }

    /// Имя переменной `let`.
    static func variable(_ expression: FormulaExpression) throws -> String {
        guard case .name(let name) = expression.kind else { throw FormulaError("Ожидалось имя переменной", at: expression.range) }
        guard !["current", "index"].contains(name) else { throw FormulaError("Имя „\(name)“ занято", at: expression.range) }
        return name
    }
}
