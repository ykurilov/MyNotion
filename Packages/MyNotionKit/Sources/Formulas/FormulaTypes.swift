/// Тип значения формулы — для «Тип: …» в редакторе, проверки при сохранении и показа итога (contracts/formulas.md).
public indirect enum FormulaType: Sendable, Hashable {
    case number
    case text
    case bool
    case date
    /// Строка базы `database` (из связи); `nil` — база неизвестна.
    case page(database: String?)
    case list(FormulaType)
    /// Неизвестно заранее: пустой список, ветки разных типов.
    case any

    /// Название для «Тип: …» и ошибок.
    public var name: String {
        switch self {
        case .number: "число"
        case .text: "текст"
        case .bool: "флажок"
        case .date: "дата"
        case .page: "страница"
        case .list: "список"
        case .any: "неизвестно"
        }
    }

    /// «ждёт …» / «получила …» — винительный падеж.
    public var accusative: String {
        switch self {
        case .date: "дату"
        case .page: "страницу"
        default: name
        }
    }

    /// Значение типа `other` подходит туда, где ждут `self`.
    func accepts(_ other: FormulaType) -> Bool {
        switch (self, other) {
        case (.any, _), (_, .any): true
        case (.list(let a), .list(let b)): a.accepts(b)
        case (.page, .page): true
        default: self == other
        }
    }

    /// Тип элемента списка (`current` в `map`, `filter` …).
    var element: FormulaType {
        if case .list(let element) = self { return element }
        return .any
    }

    /// Общий тип двух веток (`if`, элементы списка): разные — неизвестно.
    func merged(with other: FormulaType) -> FormulaType {
        if self == other { return self }
        if self == .any { return other }
        if other == .any { return self }
        if case .list(let a) = self, case .list(let b) = other { return .list(a.merged(with: b)) }
        if case .page = self, case .page = other { return .page(database: nil) }
        return .any
    }
}

/// Свойство базы глазами формулы (contracts/formulas.md, «`prop("Имя")` отдаёт»).
public struct FormulaProperty: Sendable, Hashable {
    public var id: String
    public var name: String
    /// Тип значения в формуле; у формулы — выводится из её текста (`formula`).
    public var type: FormulaType
    /// Сохранённый текст формулы (с id свойств), если свойство — формула.
    public var formula: String?
    /// Люди, кнопки и прочее, чего нет в MyNotion, — ошибка «не поддерживается».
    public var isSupported: Bool

    public init(id: String, name: String, type: FormulaType, formula: String? = nil, isSupported: Bool = true) {
        self.id = id
        self.name = name
        self.type = type
        self.formula = formula
        self.isSupported = isSupported
    }
}

/// Схема для проверки формулы: свойства своей базы (`database == nil`) и баз из связей — по названию или id.
public protocol FormulaSchema: Sendable {
    func property(_ nameOrId: String, inDatabase database: String?) -> FormulaProperty?
}

/// Ссылка на свойство в тексте формулы: место текста в `prop("…")` и найденное свойство (для замены названия на id и
/// обратно, плашек в редакторе).
public struct FormulaPropertyReference: Sendable, Hashable {
    /// Место текста `"…"` вместе с кавычками.
    public var range: Range<Int>
    public var property: FormulaProperty
}

/// Итог проверки: тип, ссылки на свойства, «живая» ли.
public struct FormulaCheck: Sendable {
    public var type: FormulaType
    public var references: [FormulaPropertyReference]
}

/// Вывод типа итога и ошибки типов с местом (contracts/formulas.md, «Редактор»): функция с аргументом не того типа,
/// неизвестная функция, нет свойства, круг формул «Итог → Сумма → Итог».
public final class FormulaTypeChecker {
    let schema: (any FormulaSchema)?
    /// Формулы, через которые пришли сюда: корень — проверяемая.
    let path: [FormulaProperty]
    var scope: [String: FormulaType] = [:]
    public private(set) var references: [FormulaPropertyReference] = []

    init(schema: (any FormulaSchema)?, path: [FormulaProperty]) {
        self.schema = schema
        self.path = path
    }

    /// Проверить формулу свойства `owner` (её круг ищется по id).
    public static func check(_ expression: FormulaExpression, schema: (any FormulaSchema)?, owner: FormulaProperty? = nil) throws(FormulaError) -> FormulaCheck {
        let checker = FormulaTypeChecker(schema: schema, path: owner.map { [$0] } ?? [])
        let type = try checker.type(of: expression)
        return FormulaCheck(type: type, references: checker.references)
    }

    /// Разобрать и проверить текст.
    public static func check(_ source: String, schema: (any FormulaSchema)?, owner: FormulaProperty? = nil) throws(FormulaError) -> FormulaCheck {
        try check(try FormulaParser.parse(source), schema: schema, owner: owner)
    }

    public func type(of expression: FormulaExpression) throws(FormulaError) -> FormulaType {
        switch expression.kind {
        case .number: return .number
        case .text: return .text
        case .bool: return .bool
        case .list(let items):
            var element: FormulaType?
            for item in items {
                let type = try type(of: item)
                element = element.map { $0.merged(with: type) } ?? type
            }
            return .list(element ?? .any)
        case .name(let name):
            if let bound = scope[name] { return bound }
            if name == "current" || name == "index" {
                throw FormulaError("„\(name)“ есть только внутри map, filter, find, some, every и sort", at: expression.range)
            }
            throw FormulaError("Неизвестное имя „\(name)“", at: expression.range)
        case .unary(let op, let operand):
            let type = try type(of: operand)
            if op == "-" {
                guard FormulaType.number.accepts(type) else {
                    throw FormulaError("Знак „-“ ждёт число, а получил \(type.accusative)", at: operand.range)
                }
                return .number
            }
            return .bool
        case .binary(let op, let left, let right):
            return try binaryType(op, left, right)
        case .conditional(let condition, let yes, let no):
            _ = try type(of: condition)
            return try type(of: yes).merged(with: try type(of: no))
        case .call(let name, let arguments):
            if name == "prop" { return try propType(arguments, call: expression) }
            guard let function = FormulaFunctionCatalog.byName[name] else {
                throw FormulaError("Функция \(name) не поддерживается в MyNotion", at: expression.range)
            }
            do {
                return try function.typing(FormulaTypingCall(name: name, arguments: arguments, range: expression.range, checker: self))
            } catch let error as FormulaError {
                throw error.range == nil ? FormulaError(error.message, at: expression.range) : error
            } catch {
                throw FormulaError("\(error)", at: expression.range)
            }
        }
    }

    private func binaryType(_ op: String, _ left: FormulaExpression, _ right: FormulaExpression) throws(FormulaError) -> FormulaType {
        let a = try type(of: left), b = try type(of: right)
        switch op {
        case "+":
            if a == .text || b == .text { return .text }
            if a == .any || b == .any { return a == .number || b == .number ? .number : .any }
            for (type, side) in [(a, left), (b, right)] where type != .number {
                throw FormulaError("Знак „+“ ждёт число или текст, а получил \(type.accusative)", at: side.range)
            }
            return .number
        case "-", "*", "/", "%", "^":
            for (type, side) in [(a, left), (b, right)] where !FormulaType.number.accepts(type) {
                throw FormulaError("Знак „\(op)“ ждёт число, а получил \(type.accusative)", at: side.range)
            }
            return .number
        case ">", ">=", "<", "<=":
            for (type, side) in [(a, left), (b, right)] where ![.number, .text, .date, .bool, .any].contains(type) {
                throw FormulaError("Знак „\(op)“ сравнивает числа, тексты или даты, а получил \(type.accusative)", at: side.range)
            }
            if !a.accepts(b) { throw FormulaError("Знак „\(op)“ сравнивает значения одного типа: \(a.name) и \(b.name)", at: right.range) }
            return .bool
        default:
            return .bool
        }
    }

    /// `prop("Имя")` своей строки и `страница.prop("Имя")` строки из связи.
    private func propType(_ arguments: [FormulaExpression], call: FormulaExpression) throws(FormulaError) -> FormulaType {
        guard arguments.count == 1 || arguments.count == 2 else { throw FormulaError("prop ждёт название свойства", at: call.range) }
        var database: String?
        if arguments.count == 2 {
            let owner = try type(of: arguments[0])
            switch owner {
            case .page(let id): database = id
            case .any: return .any
            default: throw FormulaError("prop у значения ждёт страницу, а получил \(owner.accusative)", at: arguments[0].range)
            }
            if database == nil { return .any }
        }
        let literal = arguments[arguments.count - 1]
        guard case .text(let key) = literal.kind else { throw FormulaError("prop ждёт название свойства в кавычках", at: literal.range) }
        guard let schema else { return .any }
        guard let property = schema.property(key, inDatabase: database) else { throw FormulaError("Нет свойства „\(key)“", at: literal.range) }
        guard property.isSupported else { throw FormulaError("Свойство „\(property.name)“ не поддерживается в MyNotion", at: literal.range) }
        references.append(FormulaPropertyReference(range: literal.range, property: property))
        guard let text = property.formula else { return property.type }
        // Формула: тип — из её текста; круг — ошибка.
        if let index = path.firstIndex(where: { $0.id == property.id }) {
            let chain = (path[index...].map(\.name) + [property.name]).joined(separator: " → ")
            throw FormulaError("Формула ссылается сама на себя: \(chain)", at: literal.range)
        }
        guard let expression = try? FormulaParser.parse(text) else { return .any }
        let nested = FormulaTypeChecker(schema: schema, path: path + [property])
        do {
            return try nested.type(of: expression)
        } catch where error.message.hasPrefix("Формула ссылается сама на себя") {
            throw FormulaError(error.message, at: literal.range)
        } catch {
            return .any
        }
    }

    /// Тип выражения с привязанными именами (`current`, `index`, переменные `let`).
    func type(of expression: FormulaExpression, with bindings: [String: FormulaType]) throws(FormulaError) -> FormulaType {
        let saved = scope
        scope.merge(bindings) { $1 }
        defer { scope = saved }
        return try type(of: expression)
    }
}

/// Вызов функции при проверке типов: аргументы, их типы и сообщения об ошибках.
public struct FormulaTypingCall {
    public let name: String
    public let arguments: [FormulaExpression]
    let range: Range<Int>
    let checker: FormulaTypeChecker

    var count: Int { arguments.count }

    func type(_ index: Int) throws(FormulaError) -> FormulaType { try checker.type(of: arguments[index]) }

    func type(_ index: Int, with bindings: [String: FormulaType]) throws(FormulaError) -> FormulaType {
        try checker.type(of: arguments[index], with: bindings)
    }

    /// Аргумент `index` одного из типов `expected`; ошибка — «Функция f ждёт дату, а получила текст».
    @discardableResult
    func expect(_ index: Int, _ expected: FormulaType...) throws(FormulaError) -> FormulaType {
        let actual = try type(index)
        guard expected.contains(where: { $0.accepts(actual) }) else { throw mismatch(index, expected: expected.map(\.accusative).joined(separator: " или "), got: actual) }
        return actual
    }

    func mismatch(_ index: Int, expected: String, got: FormulaType) -> FormulaError {
        FormulaError("Функция \(name) ждёт \(expected), а получила \(got.accusative)", at: arguments[index].range)
    }

    /// Число аргументов в пределах.
    func arity(_ allowed: ClosedRange<Int>) throws(FormulaError) {
        guard allowed.contains(count) else {
            let expected = allowed.lowerBound == allowed.upperBound ? "\(allowed.lowerBound)" :
                (allowed.upperBound == Int.max ? "не меньше \(allowed.lowerBound)" : "от \(allowed.lowerBound) до \(allowed.upperBound)")
            let noun = allowed.lowerBound == allowed.upperBound ? Self.values(allowed.lowerBound) : "значений"
            throw FormulaError("Функция \(name) ждёт \(expected) \(noun), а получила \(count)",
                               at: range)
        }
    }

    static func values(_ n: Int) -> String {
        let tail = n % 100
        if (11...14).contains(tail) { return "значений" }
        switch n % 10 {
        case 1: return "значение"
        case 2, 3, 4: return "значения"
        default: return "значений"
        }
    }
}
