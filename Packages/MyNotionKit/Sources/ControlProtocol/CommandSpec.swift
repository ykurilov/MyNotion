import Foundation

/// Чтение идёт без замка, запись — строго по одной (research R2).
public enum CommandAccess: String, Sendable, Hashable, Codable {
    case read, write
}

/// Тип аргумента: по нему разбор проверяет и приводит значение, а справка печатает подсказку.
public enum ArgumentType: Sendable, Hashable {
    /// Указатели: id, путь из названий, `current` (страница); имя или id (свойство, вид, вариант, строка).
    case page, block, database, property, view, option, row, version, attachment
    case string
    case int
    case number
    /// Текст JSON в самом аргументе (`--props '{"icon":"🚀"}'`).
    case json
    /// Флаг без значения.
    case bool
    /// Путь файла или папки: передаётся как есть, приложение считает относительный путь от `cwd` клиента.
    case path
    /// Файл или `-` (stdin): клиент сам читает содержимое и передаёт текст (`--markdown`).
    case content
    /// Как `content`, но содержимое — JSON (`batch --file`, `db row add --rows`).
    case jsonContent
    /// Через запятую: `a,b,c` → массив строк.
    case list
    case choice([String])

    public static let onOff = ArgumentType.choice(["on", "off"])

    /// Как тип пишется в справке и в `commands --json`.
    public var name: String {
        switch self {
        case .page: "page"
        case .block: "block"
        case .database: "database"
        case .property: "property"
        case .view: "view"
        case .option: "option"
        case .row: "row"
        case .version: "version"
        case .attachment: "attachment"
        case .string: "string"
        case .int: "int"
        case .number: "number"
        case .json: "json"
        case .bool: "bool"
        case .path: "path"
        case .content: "file|-"
        case .jsonContent: "json file|-"
        case .list: "list"
        case .choice(let values): "enum(\(values.joined(separator: "|")))"
        }
    }

    /// Подпись значения в справке: `<стр>`, `<блок>`.
    var placeholder: String {
        switch self {
        case .page: "<стр>"
        case .block: "<блок>"
        case .database: "<база>"
        case .property: "<свойство>"
        case .view: "<вид>"
        case .option: "<вариант>"
        case .row: "<строка>"
        case .version: "<версия>"
        case .attachment: "<вложение>"
        case .string: "<текст>"
        case .int: "<N>"
        case .number: "<число>"
        case .json: "<JSON>"
        case .bool: ""
        case .path: "<путь>"
        case .content: "<файл|->"
        case .jsonContent: "<файл.json|->"
        case .list: "<a,b>"
        case .choice(let values): values.joined(separator: "|")
        }
    }
}

/// Аргумент команды: позиционный (`flag == nil`) или флаг.
public struct ArgumentSpec: Sendable, Hashable {
    /// Ключ в `args` запроса.
    public var name: String
    /// Имя флага без `--`; `nil` — позиционный.
    public var flag: String?
    public var type: ArgumentType
    public var required: Bool
    /// Несколько значений: позиционный забирает остаток, флаг можно повторить или перечислить значения подряд.
    public var repeated: Bool
    public var defaultValue: ControlJSON?
    public var summary: String

    public var isPositional: Bool { flag == nil }

    public init(name: String, flag: String?, type: ArgumentType, required: Bool, repeated: Bool = false, defaultValue: ControlJSON? = nil,
                summary: String) {
        self.name = name
        self.flag = flag
        self.type = type
        self.required = required
        self.repeated = repeated
        self.defaultValue = defaultValue
        self.summary = summary
    }

    public static func positional(_ name: String, _ type: ArgumentType, _ summary: String, required: Bool = true,
                                  repeated: Bool = false) -> ArgumentSpec {
        ArgumentSpec(name: name, flag: nil, type: type, required: required, repeated: repeated, summary: summary)
    }

    /// Флаг; имя флага — ключ через дефисы (`fullWidth` → `--full-width`), если не задано своё.
    public static func flag(_ name: String, _ type: ArgumentType, _ summary: String, required: Bool = false, repeated: Bool = false,
                            default defaultValue: ControlJSON? = nil, flag: String? = nil) -> ArgumentSpec {
        ArgumentSpec(name: name, flag: flag ?? kebabCase(name), type: type, required: required, repeated: repeated,
                     defaultValue: defaultValue, summary: summary)
    }

    public static func `switch`(_ name: String, _ summary: String, flag: String? = nil) -> ArgumentSpec {
        ArgumentSpec(name: name, flag: flag ?? kebabCase(name), type: .bool, required: false, summary: summary)
    }

    static func kebabCase(_ name: String) -> String {
        name.reduce(into: "") { result, character in
            if character.isUppercase {
                result += "-" + character.lowercased()
            } else {
                result.append(character)
            }
        }
    }
}

/// Команда каталога (data-model.md, «CommandSpec»).
public struct CommandSpec: Sendable, Hashable {
    /// Слова вызова: `["db", "prop", "add"]`.
    public var words: [String]
    public var summary: String
    public var arguments: [ArgumentSpec]
    public var access: CommandAccess
    /// Можно ли шагом `batch`: только команды с точной отменой (research R6).
    public var batchable: Bool
    public var example: String
    /// Этап 005, на котором появляется обработчик.
    public var stage: Int
    /// Наборы ключей, из которых можно указать не больше одного (`after`/`first`).
    public var exclusive: [[String]]
    /// Наборы ключей, из которых нужен хотя бы один (`parent`/`root`).
    public var requiresOneOf: [[String]]
    /// Долгая команда: срок ответа по умолчанию — 10 минут, ход — строками `progress`.
    public var isLong: Bool
    /// Выполняется самой командой, без приложения (`commands`).
    public var runsWithoutApp: Bool

    public init(words: [String], summary: String, arguments: [ArgumentSpec] = [], access: CommandAccess, batchable: Bool = false,
                example: String, stage: Int, exclusive: [[String]] = [], requiresOneOf: [[String]] = [], isLong: Bool = false,
                runsWithoutApp: Bool = false) {
        self.words = words
        self.summary = summary
        self.arguments = arguments
        self.access = access
        self.batchable = batchable
        self.example = example
        self.stage = stage
        self.exclusive = exclusive
        self.requiresOneOf = requiresOneOf
        self.isLong = isLong
        self.runsWithoutApp = runsWithoutApp
    }

    /// Короткая запись: `"page create"` → слова.
    public static func command(_ invocation: String, _ summary: String, access: CommandAccess, batchable: Bool = false, stage: Int,
                               example: String, arguments: [ArgumentSpec] = [], exclusive: [[String]] = [],
                               requiresOneOf: [[String]] = [], isLong: Bool = false, runsWithoutApp: Bool = false) -> CommandSpec {
        CommandSpec(words: invocation.split(separator: " ").map(String.init), summary: summary, arguments: arguments, access: access,
                    batchable: batchable, example: example, stage: stage, exclusive: exclusive, requiresOneOf: requiresOneOf,
                    isLong: isLong, runsWithoutApp: runsWithoutApp)
    }

    /// Имя в протоколе: `db.prop.add`.
    public var name: String { words.joined(separator: ".") }
    /// Как набирать: `db prop add`.
    public var invocation: String { words.joined(separator: " ") }
    public var group: String { words[0] }

    public var positionals: [ArgumentSpec] { arguments.filter(\.isPositional) }
    public var flags: [ArgumentSpec] { arguments.filter { !$0.isPositional } }

    public func argument(named name: String) -> ArgumentSpec? {
        arguments.first { $0.name == name }
    }

    /// Строка использования: `page move <стр> [--parent <стр>] [--root] …`.
    public var usage: String {
        var parts = [invocation]
        for argument in positionals {
            let text = argument.type.placeholder + (argument.repeated ? "…" : "")
            parts.append(argument.required ? text : "[\(text)]")
        }
        for argument in flags {
            var text = "--\(argument.flag ?? argument.name)"
            if argument.type != .bool { text += " " + argument.type.placeholder }
            parts.append(argument.required ? text : "[\(text)]")
        }
        return parts.joined(separator: " ")
    }
}
