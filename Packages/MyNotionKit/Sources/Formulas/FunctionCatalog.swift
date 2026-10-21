/// Раздел списка редактора (contracts/formulas.md, «Функции»).
public enum FormulaSection: String, CaseIterable, Sendable {
    case logic = "Логика"
    case numbers = "Числа"
    case text = "Текст"
    case dates = "Даты"
    case lists = "Списки"
    case pages = "Страницы"
}

/// Пример для описания в редакторе: формула и её итог текстом (как «= 5» у Notion).
public struct FormulaExample: Sendable, Hashable {
    public let formula: String
    public let result: String

    public init(_ formula: String, _ result: String) {
        self.formula = formula
        self.result = result
    }
}

/// Функция формулы: описание для редактора, проверка типов и вычисление.
public struct FormulaFunctionInfo: Sendable {
    public let name: String
    public let section: FormulaSection
    /// Синтаксис, например `dateBetween(дата, дата, единица)`.
    public let syntax: String
    public let summary: String
    public let examples: [FormulaExample]
    let typing: @Sendable (FormulaTypingCall) throws -> FormulaType
    let body: FormulaFunction

    init(_ name: String, _ section: FormulaSection, _ syntax: String, _ summary: String, _ examples: [FormulaExample],
         typing: @escaping @Sendable (FormulaTypingCall) throws -> FormulaType, _ body: FormulaFunction) {
        self.name = name
        self.section = section
        self.syntax = syntax
        self.summary = summary
        self.examples = examples
        self.typing = typing
        self.body = body
    }
}

/// Функция формулы: со значениями аргументов или с самими выражениями (`if`, `map` — вычисляют выборочно).
public enum FormulaFunction: Sendable {
    case eager(@Sendable ([FormulaValue], FormulaEvaluator) throws -> FormulaValue)
    case lazy(@Sendable ([FormulaExpression], FormulaEvaluator) throws -> FormulaValue)
}

/// «Встроенные» редактора: знаки и константы (у Notion — раздел Built-ins).
public struct FormulaBuiltin: Sendable, Hashable {
    public let symbol: String
    public let summary: String
    public let examples: [FormulaExample]
}

/// Все функции по разделам: каждый раздел — свой файл в `Functions/`.
public enum FormulaFunctionCatalog {
    public static let all: [FormulaFunctionInfo] = FormulaFunctions.logic + FormulaFunctions.numbers + FormulaFunctions.text
        + FormulaFunctions.dates + FormulaFunctions.lists + FormulaFunctions.pages

    /// По имени; у общих имён (`length`, `concat`, `sum` …) — первая по разделам, она умеет все свои типы.
    public static let byName: [String: FormulaFunctionInfo] = all.reduce(into: [:]) { result, info in
        if result[info.name] == nil { result[info.name] = info }
    }

    /// Функции раздела по порядку: общее имя — в каждом разделе, где оно есть у Notion.
    public static func functions(in section: FormulaSection) -> [FormulaFunctionInfo] {
        all.filter { $0.section == section } + sharedNames.compactMap { name, sections in
            sections.contains(section) && byName[name]?.section != section ? byName[name] : nil
        }
    }

    /// Имена, которые Notion показывает в нескольких разделах.
    static let sharedNames: [(String, Set<FormulaSection>)] = [
        ("length", [.text, .lists]), ("concat", [.text, .lists]), ("join", [.text, .lists]),
        ("sum", [.numbers, .lists]), ("min", [.numbers, .lists]), ("max", [.numbers, .lists]),
        ("mean", [.numbers, .lists]), ("median", [.numbers, .lists]),
    ]

    public static let builtins: [FormulaBuiltin] = [
        FormulaBuiltin(symbol: "+", summary: "Складывает два числа или склеивает текст.", examples: [FormulaExample("3 + 2", "5"), FormulaExample("\"a\" + \"b\"", "ab")]),
        FormulaBuiltin(symbol: "-", summary: "Вычитает одно число из другого.", examples: [FormulaExample("5 - 3", "2")]),
        FormulaBuiltin(symbol: "*", summary: "Умножает два числа.", examples: [FormulaExample("5 * 3", "15")]),
        FormulaBuiltin(symbol: "/", summary: "Делит одно число на другое; на ноль — пусто.", examples: [FormulaExample("6 / 3", "2")]),
        FormulaBuiltin(symbol: "%", summary: "Остаток от деления.", examples: [FormulaExample("7 % 3", "1")]),
        FormulaBuiltin(symbol: "^", summary: "Возводит число в степень.", examples: [FormulaExample("2 ^ 3", "8")]),
        FormulaBuiltin(symbol: ">", summary: "Больше ли первое значение второго.", examples: [FormulaExample("3 > 2", "true")]),
        FormulaBuiltin(symbol: ">=", summary: "Больше или равно.", examples: [FormulaExample("3 >= 3", "true")]),
        FormulaBuiltin(symbol: "<", summary: "Меньше ли первое значение второго.", examples: [FormulaExample("2 < 3", "true")]),
        FormulaBuiltin(symbol: "<=", summary: "Меньше или равно.", examples: [FormulaExample("3 <= 2", "false")]),
        FormulaBuiltin(symbol: "==", summary: "Равны ли значения.", examples: [FormulaExample("2 == 2", "true")]),
        FormulaBuiltin(symbol: "!=", summary: "Различаются ли значения.", examples: [FormulaExample("2 != 3", "true")]),
        FormulaBuiltin(symbol: "and", summary: "Истина, если истинны оба условия. То же — &&.", examples: [FormulaExample("true and false", "false")]),
        FormulaBuiltin(symbol: "or", summary: "Истина, если истинно хотя бы одно. То же — ||.", examples: [FormulaExample("true or false", "true")]),
        FormulaBuiltin(symbol: "not", summary: "Обратное значение. То же — !.", examples: [FormulaExample("not true", "false")]),
        FormulaBuiltin(symbol: "? :", summary: "Если условие истинно — первое значение, иначе второе.", examples: [FormulaExample("2 > 1 ? \"да\" : \"нет\"", "да")]),
        FormulaBuiltin(symbol: "true", summary: "Истина — флажок отмечен.", examples: [FormulaExample("true", "true")]),
        FormulaBuiltin(symbol: "false", summary: "Ложь — флажок снят.", examples: [FormulaExample("false", "false")]),
    ]
}

/// Разделы функций — расширения в `Functions/`.
public enum FormulaFunctions {}
