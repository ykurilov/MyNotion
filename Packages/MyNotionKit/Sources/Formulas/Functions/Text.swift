import Foundation

extension FormulaFunctions {
    /// Текст, число и флажок годятся там, где ждут текст (`test(5, "\\d")`).
    private static let textLike: [FormulaType] = [.text, .number, .bool]

    private static func text(_ name: String, _ syntax: String, _ summary: String, _ examples: [FormulaExample],
                             _ parameters: [[FormulaType]], optional: Int = 0, _ result: FormulaType,
                             _ body: @escaping @Sendable ([FormulaValue], FormulaEvaluator) throws -> FormulaValue) -> FormulaFunctionInfo {
        FormulaFunctionInfo(name, .text, syntax, summary, examples, typing: Typing.fixed(parameters, optional: optional, result), .eager(body))
    }

    /// Текст аргумента: число и флажок — как у `format`.
    private static func string(_ arguments: [FormulaValue], _ index: Int, _ evaluator: FormulaEvaluator) -> String? {
        guard index < arguments.count, arguments[index] != .empty else { return nil }
        return FormulaText.format(arguments[index], context: evaluator.context)
    }

    /// Регулярное выражение ICU (как у Notion); ошибка шаблона — ошибка строки.
    static func regex(_ pattern: String) throws -> NSRegularExpression {
        do { return try RegexCache.shared.regex(pattern) } catch { throw FormulaError("Неверное регулярное выражение „\(pattern)“") }
    }

    static let text: [FormulaFunctionInfo] = [
        FormulaFunctionInfo("length", .text, "length(текст или список)", "Длина текста в символах или число элементов списка.",
                            [FormulaExample(#"length("Привет")"#, "6"), FormulaExample("length([1, 2, 3])", "3")],
                            typing: Typing.fixed([[.text, .list(.any)]], .number),
                            .eager { arguments, _ in
                                switch arguments[0] {
                                case .list(let items): .number(Double(items.count))
                                case .text(let text): .number(Double(text.count))
                                default: .number(0)
                                }
                            }),
        FormulaFunctionInfo("concat", .text, "concat(текст или список, …)", "Склеивает тексты или соединяет списки в один.",
                            [FormulaExample(#"concat("до", "бро")"#, "добро"), FormulaExample("concat([1, 2], [3])", "1,2,3")],
                            typing: { call in
                                try call.arity(1...Int.max)
                                let types = try (0..<call.count).map { try call.type($0) }
                                if types.allSatisfy({ FormulaType.list(.any).accepts($0) }) {
                                    return .list(types.map(\.element).reduce(types[0].element) { $0.merged(with: $1) })
                                }
                                for (index, type) in types.enumerated() where !textLike.contains(where: { $0.accepts(type) }) {
                                    throw call.mismatch(index, expected: "текст или список", got: type)
                                }
                                return .text
                            },
                            .eager { arguments, evaluator in
                                if arguments.allSatisfy({ $0.list != nil || $0 == .empty }), arguments.contains(where: { $0.list != nil }) {
                                    return .list(arguments.flatMap { $0.list ?? [] })
                                }
                                return .text(arguments.map { FormulaText.format($0, context: evaluator.context) }.joined())
                            }),
        FormulaFunctionInfo("join", .text, "join(список, разделитель)", "Соединяет элементы списка в текст через разделитель.",
                            [FormulaExample(#"join(["a", "b", "c"], ", ")"#, "a, b, c")],
                            typing: Typing.fixed([[.list(.any)], [.text]], .text),
                            .eager { arguments, evaluator in
                                guard let items = arguments.list(0) else { return .text("") }
                                return .text(items.map { FormulaText.format($0, context: evaluator.context) }.joined(separator: arguments.text(1) ?? ""))
                            }),
        text("split", "split(текст, разделитель)", "Делит текст на список по разделителю.",
             [FormulaExample(#"split("a,b,c", ",")"#, "a,b,c"), FormulaExample(#"length(split("a b c", " "))"#, "3")],
             [[.text], [.text]], .list(.text)) { arguments, _ in
            guard let text = arguments.text(0) else { return .list([]) }
            let separator = arguments.text(1) ?? ""
            let parts = separator.isEmpty ? text.map(String.init) : text.components(separatedBy: separator)
            return .list(parts.map(FormulaValue.text))
        },
        text("substring", "substring(текст, от, до?)", "Часть текста с номера «от» (с 0) до номера «до», не включая его.",
             [FormulaExample(#"substring("Notion", 0, 3)"#, "Not"), FormulaExample(#"substring("Notion", 3)"#, "ion")],
             [[.text], [.number], [.number]], optional: 1, .text) { arguments, _ in
            guard let text = arguments.text(0) else { return .text("") }
            let characters = Array(text)
            // Как substring в JavaScript: отрицательное — 0, «от» больше «до» — меняются местами.
            func bound(_ value: Double?, _ fallback: Int) -> Int {
                guard let value, !value.isNaN else { return fallback }
                return Swift.min(Swift.max(0, Int(value.rounded(.towardZero))), characters.count)
            }
            var start = bound(arguments.number(1), 0), end = arguments.count > 2 ? bound(arguments.number(2), characters.count) : characters.count
            if start > end { swap(&start, &end) }
            return .text(String(characters[start..<end]))
        },
        FormulaFunctionInfo("contains", .text, "contains(текст, искомое)", "Истина, если в тексте есть искомое (у списка — такой элемент).",
                            [FormulaExample(#"contains("Notion", "tion")"#, "true"), FormulaExample(#"contains("Notion", "x")"#, "false")],
                            typing: Typing.fixed([textLike + [.list(.any)], textLike], .bool),
                            .eager { arguments, evaluator in
                                if let items = arguments.list(0) {
                                    return .bool(items.contains { $0 == arguments[1] || FormulaText.format($0, context: evaluator.context) == string(arguments, 1, evaluator) })
                                }
                                guard let text = string(arguments, 0, evaluator), let search = string(arguments, 1, evaluator) else { return .bool(false) }
                                return .bool(search.isEmpty || text.contains(search))
                            }),
        text("startsWith", "startsWith(текст, начало)", "Истина, если текст начинается с указанного.",
             [FormulaExample(#"startsWith("Notion", "No")"#, "true")], [textLike, textLike], .bool) { arguments, evaluator in
            .bool((string(arguments, 0, evaluator) ?? "").hasPrefix(string(arguments, 1, evaluator) ?? ""))
        },
        text("endsWith", "endsWith(текст, конец)", "Истина, если текст заканчивается указанным.",
             [FormulaExample(#"endsWith("Notion", "on")"#, "true")], [textLike, textLike], .bool) { arguments, evaluator in
            .bool((string(arguments, 0, evaluator) ?? "").hasSuffix(string(arguments, 1, evaluator) ?? ""))
        },
        text("lower", "lower(текст)", "Текст строчными буквами.", [FormulaExample(#"lower("NOTION")"#, "notion")], [[.text]], .text) { arguments, _ in
            .text((arguments.text(0) ?? "").lowercased())
        },
        text("upper", "upper(текст)", "Текст заглавными буквами.", [FormulaExample(#"upper("notion")"#, "NOTION")], [[.text]], .text) { arguments, _ in
            .text((arguments.text(0) ?? "").uppercased())
        },
        text("trim", "trim(текст)", "Убирает пробелы в начале и в конце.", [FormulaExample(#"trim("  Notion  ")"#, "Notion")], [[.text]], .text) { arguments, _ in
            .text((arguments.text(0) ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        },
        text("repeat", "repeat(текст, раз)", "Повторяет текст указанное число раз.", [FormulaExample(#"repeat("ab", 3)"#, "ababab")],
             [textLike, [.number]], .text) { arguments, evaluator in
            let times = Swift.max(0, Int(arguments.number(1) ?? 0))
            guard times <= 10_000 else { throw FormulaError("Слишком много повторов") }
            return .text(String(repeating: string(arguments, 0, evaluator) ?? "", count: times))
        },
        text("padStart", "padStart(текст, длина, заполнитель)", "Дополняет текст слева до нужной длины.",
             [FormulaExample(#"padStart("5", 3, "0")"#, "005")], [textLike, [.number], [.text]], .text) { arguments, evaluator in
            .text(pad(string(arguments, 0, evaluator) ?? "", to: arguments.number(1) ?? 0, with: arguments.text(2) ?? " ", atStart: true))
        },
        text("padEnd", "padEnd(текст, длина, заполнитель)", "Дополняет текст справа до нужной длины.",
             [FormulaExample(#"padEnd("5", 3, "0")"#, "500")], [textLike, [.number], [.text]], .text) { arguments, evaluator in
            .text(pad(string(arguments, 0, evaluator) ?? "", to: arguments.number(1) ?? 0, with: arguments.text(2) ?? " ", atStart: false))
        },
        text("replace", "replace(текст, шаблон, замена)", "Заменяет первое совпадение с регулярным выражением; $1 — первая группа.",
             [FormulaExample(#"replace("1-2-3", "-", "+")"#, "1+2-3")], [textLike, [.text], [.text]], .text) { arguments, evaluator in
            .text(try replace(string(arguments, 0, evaluator) ?? "", arguments.text(1) ?? "", arguments.text(2) ?? "", all: false))
        },
        text("replaceAll", "replaceAll(текст, шаблон, замена)", "Заменяет все совпадения с регулярным выражением.",
             [FormulaExample(#"replaceAll("1-2-3", "-", "+")"#, "1+2+3")], [textLike, [.text], [.text]], .text) { arguments, evaluator in
            .text(try replace(string(arguments, 0, evaluator) ?? "", arguments.text(1) ?? "", arguments.text(2) ?? "", all: true))
        },
        text("test", "test(текст, шаблон)", "Истина, если текст подходит под регулярное выражение.",
             [FormulaExample(#"test("Notion 2", "\\d")"#, "true"), FormulaExample(#"test("Notion", "^n")"#, "false")],
             [textLike, [.text]], .bool) { arguments, evaluator in
            let text = string(arguments, 0, evaluator) ?? ""
            return .bool(try regex(arguments.text(1) ?? "").firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil)
        },
        text("match", "match(текст, шаблон)", "Все совпадения с регулярным выражением списком.",
             [FormulaExample(#"match("a1 b22 c3", "\\d+")"#, "1,22,3")], [textLike, [.text]], .list(.text)) { arguments, evaluator in
            let text = string(arguments, 0, evaluator) ?? ""
            let matches = try regex(arguments.text(1) ?? "").matches(in: text, range: NSRange(text.startIndex..., in: text))
            return .list(matches.compactMap { Range($0.range, in: text).map { .text(String(text[$0])) } })
        },
        FormulaFunctionInfo("format", .text, "format(значение)", "Любое значение в текст.",
                            [FormulaExample("format(1234)", "1234"), FormulaExample("format(true)", "true")],
                            typing: { call in try call.arity(1...1); _ = try call.type(0); return .text },
                            .eager { arguments, evaluator in .text(FormulaText.format(arguments[0], context: evaluator.context)) }),
    ]

    static func pad(_ text: String, to length: Double, with filler: String, atStart: Bool) -> String {
        let target = Int(Swift.min(length, 10_000))
        guard text.count < target, !filler.isEmpty else { return text }
        var padding = ""
        while padding.count < target - text.count { padding += filler }
        padding = String(padding.prefix(target - text.count))
        return atStart ? padding + text : text + padding
    }

    static func replace(_ text: String, _ pattern: String, _ template: String, all: Bool) throws -> String {
        let expression = try regex(pattern)
        let whole = NSRange(text.startIndex..., in: text)
        if all { return expression.stringByReplacingMatches(in: text, range: whole, withTemplate: template) }
        guard let first = expression.firstMatch(in: text, range: whole) else { return text }
        let replacement = expression.replacementString(for: first, in: text, offset: 0, template: template)
        return (text as NSString).replacingCharacters(in: first.range, with: replacement)
    }
}

/// Скомпилированные регулярные выражения: формула одна на 10 000 строк — шаблон компилируется раз.
final class RegexCache: @unchecked Sendable {
    static let shared = RegexCache()
    private let lock = NSLock()
    private var cache: [String: NSRegularExpression] = [:]

    func regex(_ pattern: String) throws -> NSRegularExpression {
        lock.lock()
        defer { lock.unlock() }
        if let known = cache[pattern] { return known }
        let compiled = try NSRegularExpression(pattern: pattern)
        if cache.count > 200 { cache.removeAll() }
        cache[pattern] = compiled
        return compiled
    }
}
