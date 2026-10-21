import Foundation

extension FormulaFunctions {
    /// Функция одного числа: пустое — пусто.
    private static func unary(_ name: String, _ syntax: String, _ summary: String, _ examples: [FormulaExample],
                              _ body: @escaping @Sendable (Double) -> Double) -> FormulaFunctionInfo {
        FormulaFunctionInfo(name, .numbers, syntax, summary, examples, typing: Typing.numbers(1),
                            .eager { arguments, _ in arguments.number(0).map { .number(body($0)) } ?? .empty })
    }

    /// Функция двух чисел через знак (`subtract` — это `-`).
    private static func binary(_ name: String, _ op: String, _ summary: String, _ examples: [FormulaExample]) -> FormulaFunctionInfo {
        FormulaFunctionInfo(name, .numbers, "\(name)(число, число)", summary, examples, typing: Typing.numbers(2),
                            .eager { arguments, _ in try FormulaOperators.binary(op, arguments[0], arguments[1]) })
    }

    /// Итог над числами и списками чисел; ни одного числа — `none`.
    private static func aggregate(_ name: String, _ summary: String, _ examples: [FormulaExample], none: FormulaValue,
                                  _ body: @escaping @Sendable ([Double]) -> Double) -> FormulaFunctionInfo {
        FormulaFunctionInfo(name, .numbers, "\(name)(число, …)", summary, examples, typing: Typing.numbersOrLists,
                            .eager { arguments, _ in
                                let numbers = arguments.flattenedNumbers
                                return numbers.isEmpty ? none : .number(body(numbers))
                            })
    }

    static let numbers: [FormulaFunctionInfo] = [
        FormulaFunctionInfo("add", .numbers, "add(число, число)", "Складывает два числа или склеивает текст. То же — +.",
                            [FormulaExample("add(5, 10)", "15"), FormulaExample("add(-1, 2)", "1")],
                            typing: { call in
                                try call.arity(2...2)
                                let a = try call.type(0), b = try call.type(1)
                                if a == .text || b == .text { return .text }
                                for (index, type) in [a, b].enumerated() where !FormulaType.number.accepts(type) {
                                    throw call.mismatch(index, expected: "число или текст", got: type)
                                }
                                return .number
                            },
                            .eager { arguments, _ in try FormulaOperators.binary("+", arguments[0], arguments[1]) }),
        binary("subtract", "-", "Вычитает второе число из первого. То же — -.", [FormulaExample("subtract(5, 10)", "-5")]),
        binary("multiply", "*", "Умножает два числа. То же — *.", [FormulaExample("multiply(5, 10)", "50")]),
        binary("divide", "/", "Делит первое число на второе; на ноль — пусто. То же — /.", [FormulaExample("divide(10, 4)", "2.5")]),
        binary("mod", "%", "Остаток от деления первого числа на второе. То же — %.", [FormulaExample("mod(7, 3)", "1"), FormulaExample("mod(-7, 3)", "-1")]),
        binary("pow", "^", "Возводит первое число в степень второго. То же — ^.", [FormulaExample("pow(2, 10)", "1024")]),
        unary("abs", "abs(число)", "Модуль числа — без знака.", [FormulaExample("abs(-3)", "3")], Swift.abs),
        FormulaFunctionInfo("round", .numbers, "round(число, знаков?)",
                            "Округляет до целого или до указанного числа знаков после запятой; половину — вверх.",
                            [FormulaExample("round(4.5)", "5"), FormulaExample("round(-4.5)", "-4"), FormulaExample("round(4.567, 2)", "4.57")],
                            typing: Typing.numbers(2, optional: 1),
                            .eager { arguments, _ in
                                guard let number = arguments.number(0) else { return .empty }
                                let places = arguments.count > 1 ? (arguments.number(1) ?? 0) : 0
                                let scale = Foundation.pow(10, places.rounded(.towardZero))
                                return .number((number * scale + 0.5).rounded(.down) / scale)
                            }),
        unary("ceil", "ceil(число)", "Округляет вверх до целого.", [FormulaExample("ceil(4.2)", "5"), FormulaExample("ceil(-4.2)", "-4")]) { $0.rounded(.up) },
        unary("floor", "floor(число)", "Округляет вниз до целого.", [FormulaExample("floor(4.8)", "4"), FormulaExample("floor(-4.2)", "-5")]) { $0.rounded(.down) },
        unary("sqrt", "sqrt(число)", "Квадратный корень; у отрицательного — пусто.", [FormulaExample("sqrt(16)", "4")], Foundation.sqrt),
        unary("cbrt", "cbrt(число)", "Кубический корень.", [FormulaExample("cbrt(27)", "3"), FormulaExample("cbrt(-8)", "-2")], Foundation.cbrt),
        unary("exp", "exp(число)", "Число e в указанной степени.", [FormulaExample("exp(0)", "1")], Foundation.exp),
        unary("ln", "ln(число)", "Натуральный логарифм.", [FormulaExample("ln(e())", "1")], Foundation.log),
        unary("log10", "log10(число)", "Десятичный логарифм.", [FormulaExample("log10(1000)", "3")], Foundation.log10),
        unary("log2", "log2(число)", "Двоичный логарифм.", [FormulaExample("log2(64)", "6")], Foundation.log2),
        unary("sign", "sign(число)", "Знак числа: 1, -1 или 0.", [FormulaExample("sign(-5)", "-1"), FormulaExample("sign(0)", "0")]) { $0 > 0 ? 1 : ($0 < 0 ? -1 : 0) },
        aggregate("min", "Наименьшее из чисел и списков чисел.", [FormulaExample("min(4, 1, 9)", "1"), FormulaExample("min([4, 1], 2)", "1")], none: .empty) { $0.min()! },
        aggregate("max", "Наибольшее из чисел и списков чисел.", [FormulaExample("max(4, 1, 9)", "9"), FormulaExample("max([4, 1], 2)", "4")], none: .empty) { $0.max()! },
        aggregate("sum", "Сумма чисел и списков чисел.", [FormulaExample("sum(1, 2, 3)", "6"), FormulaExample("sum([1, 2], 3)", "6")], none: .number(0)) { $0.reduce(0, +) },
        aggregate("mean", "Среднее арифметическое.", [FormulaExample("mean(1, 2, 3, 6)", "3")], none: .empty) { $0.reduce(0, +) / Double($0.count) },
        aggregate("median", "Медиана — среднее по порядку значение.", [FormulaExample("median(1, 5, 2)", "2"), FormulaExample("median([1, 2, 3, 4])", "2.5")],
                  none: .empty) { numbers in
            let sorted = numbers.sorted(), middle = sorted.count / 2
            return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
        },
        FormulaFunctionInfo("pi", .numbers, "pi()", "Число π.", [FormulaExample("pi()", "3.141592653589793")], typing: Typing.numbers(0),
                            .eager { _, _ in .number(Double.pi) }),
        FormulaFunctionInfo("e", .numbers, "e()", "Число e — основание натурального логарифма.", [FormulaExample("e()", "2.718281828459045")],
                            typing: Typing.numbers(0), .eager { _, _ in .number(M_E) }),
        FormulaFunctionInfo("toNumber", .numbers, "toNumber(значение)",
                            "Значение в число: текст с числом, флажок — 1 или 0, дата — миллисекунды с 1970 года. Не число — пусто.",
                            [FormulaExample(#"toNumber("42")"#, "42"), FormulaExample("toNumber(true)", "1"), FormulaExample(#"toNumber("abc")"#, "")],
                            typing: { call in try call.arity(1...1); _ = try call.type(0); return .number },
                            .eager { arguments, _ in toNumber(arguments[0]) }),
    ]

    static func toNumber(_ value: FormulaValue) -> FormulaValue {
        switch value {
        case .number: return value
        case .bool(let flag): return .number(flag ? 1 : 0)
        case .date(let date): return .number((date.start.timeIntervalSince1970 * 1_000).rounded())
        case .text(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let number = Double(trimmed), number.isFinite else { return .empty }
            return .number(number)
        default: return .empty
        }
    }
}
