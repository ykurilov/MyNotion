import Foundation

/// Каталог всех команд (contracts/commands.md) — один на клиент и приложение (research R9): по нему клиент печатает
/// справку и разбирает аргументы, приложение проверяет запрос. Группы описаны в `Catalog/<Группа>.swift`.
public enum CommandCatalog {
    public static let all: [CommandSpec] = service + pages + blocks + databases + library + windowCommands + transfer

    private static let byName: [String: CommandSpec] = Dictionary(all.map { ($0.name, $0) }) { first, _ in first }

    public static func spec(for name: String) -> CommandSpec? {
        byName[name]
    }

    public static func spec(words: [String]) -> CommandSpec? {
        byName[words.joined(separator: ".")]
    }

    /// Первые слова команд по порядку каталога.
    public static var groups: [String] {
        var seen: Set<String> = []
        return all.map(\.group).filter { seen.insert($0).inserted }
    }

    static let groupSummaries: [String: String] = [
        "app": "Состояние приложения", "commands": "Каталог команд", "batch": "Несколько команд одним шагом с откатом",
        "page": "Страницы: дерево, чтение, запись Markdown, перенос, иконка, обложка", "trash": "Корзина",
        "block": "Блоки страницы", "db": "Базы: свойства, варианты, строки, ячейки, виды", "search": "Поиск",
        "favorites": "Избранное", "recents": "Недавние", "template": "Страницы-шаблоны", "history": "История версий",
        "attachment": "Вложения", "window": "Окна", "open": "Открыть страницу в окне", "tab": "Вкладки", "nav": "Назад и вперёд",
        "import": "Импорт из Notion", "export": "Выгрузка в Markdown", "sync": "Синхронизация",
    ]

    /// Ключи общих флагов, которые доходят до приложения в `args`.
    public static let sharedArgumentNames: Set<String> = ["includeTrashed", "limit", "cursor"]
    /// Списки: по умолчанию и наибольший размер страницы (FR-409).
    public static let defaultLimit = 200
    public static let maxLimit = 1_000

    /// Весь каталог машинно (`commands --json`): порядок — порядок каталога, ключи по алфавиту.
    public static var json: ControlJSON {
        [
            "protocol": .number(Double(ControlProtocolVersion.current)),
            "commands": .array(all.map(\.json)),
            "globalFlags": .array(GlobalFlag.allCases.map { flag in
                ["flag": .string("--" + flag.rawValue), "summary": .string(flag.summary)]
            }),
        ]
    }

    /// Ближайшая по написанию команда: подсказка к опечатке.
    public static func suggestion(for words: [String]) -> CommandSpec? {
        let typed = words.joined(separator: " ")
        return all.min { EditDistance.between(typed, $0.invocation) < EditDistance.between(typed, $1.invocation) }
            .flatMap { EditDistance.between(typed, $0.invocation) <= max(3, typed.count / 3) ? $0 : nil }
    }

    /// Проверка и приведение `args` запроса по каталогу — до выполнения (FR-408). Пропущенное со значением по умолчанию
    /// дополняется; содержимое файлов (`content`) приходит уже текстом от клиента.
    public static func normalized(_ args: [String: ControlJSON], for spec: CommandSpec) throws(ControlError) -> [String: ControlJSON] {
        var result = args
        for (key, value) in args {
            if sharedArgumentNames.contains(key) {
                try checkShared(key, value)
                continue
            }
            guard let argument = spec.argument(named: key) else {
                throw ControlError(.invalidArgument, "У команды «\(spec.invocation)» нет аргумента «\(key)»",
                                   hint: "Справка: mynotion \(spec.invocation) --help",
                                   details: ["argument": .string(key), "allowed": .array(spec.arguments.map { .string($0.name) })])
            }
            try check(value, of: argument, in: spec)
        }
        for argument in spec.arguments where result[argument.name] == nil {
            if let value = argument.defaultValue, argument.type != .content, argument.type != .jsonContent {
                result[argument.name] = value
            } else if argument.required {
                throw missing(argument, in: spec)
            }
        }
        for group in spec.exclusive {
            let given = group.filter { isGiven(result[$0]) }
            if given.count > 1 {
                throw ControlError(.invalidArgument, "Нельзя вместе: \(given.map { spec.label(of: $0) }.joined(separator: " и "))",
                                   hint: "Оставьте один из них", details: ["conflicting": .array(given.map { .string($0) })])
            }
        }
        for group in spec.requiresOneOf where !group.contains(where: { isGiven(result[$0]) }) {
            let labels = group.map { spec.label(of: $0) }
            throw ControlError(.missingArgument, "Нужен один из аргументов: \(labels.joined(separator: ", "))",
                               hint: "Пример: \(spec.example)", details: ["oneOf": .array(group.map { .string($0) })])
        }
        return result
    }

    static func missing(_ argument: ArgumentSpec, in spec: CommandSpec) -> ControlError {
        ControlError(.missingArgument, "Не хватает аргумента \(spec.label(of: argument.name))",
                     hint: "Пример: \(spec.example)", details: ["argument": .string(argument.name)])
    }

    private static func isGiven(_ value: ControlJSON?) -> Bool {
        guard let value else { return false }
        return value != .bool(false)
    }

    private static func checkShared(_ key: String, _ value: ControlJSON) throws(ControlError) {
        switch key {
        case "limit":
            guard let limit = value.int, (1...maxLimit).contains(limit) else {
                throw ControlError(.invalidArgument, "--limit — целое от 1 до \(maxLimit)", hint: "Остальное — через --cursor",
                                   details: ["argument": "limit", "max": .number(Double(maxLimit))])
            }
        case "cursor":
            guard value.string != nil else { throw ControlError(.invalidValue, "--cursor — текст из nextCursor прошлого ответа") }
        default:
            guard value.bool != nil else { throw ControlError(.invalidValue, "--\(ArgumentSpec.kebabCase(key)) — флаг без значения") }
        }
    }

    private static func check(_ value: ControlJSON, of argument: ArgumentSpec, in spec: CommandSpec) throws(ControlError) {
        if argument.repeated, case .array(let items) = value {
            for item in items { try checkSingle(item, of: argument, in: spec) }
        } else {
            try checkSingle(value, of: argument, in: spec)
        }
    }

    private static func checkSingle(_ value: ControlJSON, of argument: ArgumentSpec, in spec: CommandSpec) throws(ControlError) {
        let isValid: Bool = switch argument.type {
        case .page, .block, .database, .property, .view, .option, .row, .version, .attachment, .string, .path, .content:
            value.string != nil
        case .int: value.int != nil
        case .number: value.number != nil
        case .json, .jsonContent: true
        case .bool: value.bool != nil
        case .list: value.array?.allSatisfy { $0.string != nil } ?? (value.string != nil)
        case .choice(let values): value.string.map(values.contains) ?? false
        }
        guard isValid else {
            var details: [String: ControlJSON] = ["argument": .string(argument.name), "expected": .string(argument.type.name)]
            if case .choice(let values) = argument.type { details["allowed"] = .array(values.map { .string($0) }) }
            throw ControlError(.invalidValue, "Неверное значение \(spec.label(of: argument.name)): нужно \(argument.type.name)",
                               hint: "Пример: \(spec.example)", details: .object(details))
        }
    }
}

extension CommandSpec {
    /// Как аргумент назван в сообщении: `--title` или `<стр>`.
    func label(of name: String) -> String {
        guard let argument = argument(named: name) else { return "--" + ArgumentSpec.kebabCase(name) }
        return argument.flag.map { "--" + $0 } ?? argument.type.placeholder
    }

    var json: ControlJSON {
        [
            "name": .string(name), "invocation": .string(invocation), "group": .string(group), "summary": .string(summary),
            "access": .string(access.rawValue), "batchable": .bool(batchable), "stage": .number(Double(stage)),
            "example": .string(example), "long": .bool(isLong), "withoutApp": .bool(runsWithoutApp), "usage": .string(usage),
            "arguments": .array(arguments.map(\.json)),
            "exclusive": .array(exclusive.map { .array($0.map { .string($0) }) }),
            "oneOf": .array(requiresOneOf.map { .array($0.map { .string($0) }) }),
        ]
    }
}

extension ArgumentSpec {
    var json: ControlJSON {
        var object: [String: ControlJSON] = [
            "name": .string(name), "positional": .bool(isPositional), "type": .string(type.name), "required": .bool(required),
            "repeated": .bool(repeated), "summary": .string(summary),
        ]
        if let flag { object["flag"] = .string("--" + flag) }
        if let defaultValue { object["default"] = defaultValue }
        return .object(object)
    }
}

/// Расстояние правки (Левенштейн) — для подсказок к опечаткам.
enum EditDistance {
    static func between(_ lhs: String, _ rhs: String) -> Int {
        let a = Array(lhs), b = Array(rhs)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}
