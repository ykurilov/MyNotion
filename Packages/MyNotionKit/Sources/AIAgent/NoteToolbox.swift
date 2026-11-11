import AIModels
import ControlProtocol
import Foundation

/// Инструменты агента — команды `mynotion` из каталога 005, выполняются тем же исполнителем, что и у `mynotion`:
/// с отменой, под замком записи и с версией в истории от имени агента. Список задан явно: новые команды каталога
/// сами к агенту не попадают. Удалить навсегда, пакеты, файлы, синхронизация и окна — вне списка.
public struct NoteToolbox: Sendable {
    public typealias Runner = @Sendable (ControlRequest) async -> ControlResponse

    /// Так правки агента подписаны в истории версий.
    public static let agentName = "ИИ-агент"
    /// Предел вывода одного вызова для модели.
    public static let maxOutputLength = 24_000

    public static let commandNames = [
        "page.tree", "page.get", "page.read", "page.create", "page.write", "page.append", "page.rename", "page.move",
        "page.duplicate", "page.trash", "page.restore", "page.icon", "page.layout", "trash.list", "search", "recents",
        "favorites.list", "favorites.add", "favorites.remove", "template.list",
        "block.kinds", "block.get", "block.insert", "block.update", "block.table-widths", "block.move", "block.move-to-page", "block.indent",
        "block.outdent", "block.check", "block.uncheck", "block.delete",
        "db.create", "db.schema", "db.rows", "db.prop.add", "db.prop.update", "db.prop.type", "db.prop.move", "db.prop.delete",
        "db.prop.restore", "db.option.add", "db.option.rename", "db.option.color", "db.option.delete", "db.row.add",
        "db.row.update", "db.row.trash", "db.row.restore", "db.cell.set", "db.relation.link", "db.relation.unlink",
        "db.view.list", "db.view.add", "db.view.rename", "db.view.update", "db.view.delete", "db.template.list",
        "history.list", "history.show", "history.restore", "open",
    ]

    public static let tools = makeTools()

    private static let specsByTool: [String: CommandSpec] = Dictionary(
        commandNames.compactMap { name in CommandCatalog.spec(for: name).map { (toolName(for: name), $0) } }) { first, _ in first }

    private let runner: Runner

    public init(runner: @escaping Runner) {
        self.runner = runner
    }

    static func toolName(for command: String) -> String {
        command.replacingOccurrences(of: ".", with: "_")
    }

    static func makeTools() -> [ModelTool] {
        commandNames.compactMap { name in
            CommandCatalog.spec(for: name).map { ModelTool(name: toolName(for: name), description: description(of: $0), parameters: schema(of: $0)) }
        }
    }

    public func run(_ call: ModelToolCall) async -> ToolOutcome {
        guard let spec = Self.specsByTool[call.name] else {
            return ToolOutcome(ok: false, output: "Ошибка: инструмента «\(call.name)» нет.")
        }
        let text = call.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = text.isEmpty ? .object([:]) : try? ControlJSON(parsing: text), let arguments = parsed.object else {
            return ToolOutcome(ok: false, output: "Ошибка: аргументы — не объект JSON. Пришли их заново одним объектом.")
        }
        let request = ControlRequest(command: spec.name, args: Self.coerced(arguments, for: spec), agent: Self.agentName)
        let response = await runner(request)
        guard response.ok else {
            let error = response.error
            var parts = ["Ошибка: " + (error?.message ?? "команда не выполнена")]
            if let hint = error?.hint { parts.append("Подсказка: " + hint) }
            if let details = error?.details { parts.append("Подробности: " + details.encodedText()) }
            return ToolOutcome(ok: false, output: Self.truncated(parts.joined(separator: "\n")))
        }
        var output = (response.data ?? .object([:])).encodedText()
        if !response.warnings.isEmpty {
            output += "\nПредупреждения: " + response.warnings.map(\.message).joined(separator: "; ")
        }
        return ToolOutcome(ok: true, output: Self.truncated(output))
    }

    // MARK: - Описание для модели

    private static func description(of spec: CommandSpec) -> String {
        var parts = [spec.summary + "."]
        for group in spec.exclusive { parts.append("Не вместе: \(group.joined(separator: ", ")).") }
        for group in spec.requiresOneOf { parts.append("Нужен один из: \(group.joined(separator: ", ")).") }
        return parts.joined(separator: " ")
    }

    private static func schema(of spec: CommandSpec) -> ControlJSON {
        var properties: [String: ControlJSON] = [:]
        for argument in spec.arguments {
            properties[argument.name] = schema(of: argument)
        }
        return ["type": "object", "properties": .object(properties),
                "required": .array(spec.arguments.filter(\.required).map { .string($0.name) })]
    }

    private static func schema(of argument: ArgumentSpec) -> ControlJSON {
        let summary = argument.summary
        let single: ControlJSON = switch argument.type {
        case .page: ["type": "string", "description": .string(summary + ": id, путь из названий через / или current")]
        case .database: ["type": "string", "description": .string(summary + ": id, путь из названий или название базы")]
        case .block, .version, .attachment: ["type": "string", "description": .string(summary + ": id")]
        case .property, .view, .option, .row: ["type": "string", "description": .string(summary + ": имя или id")]
        case .string, .path: ["type": "string", "description": .string(summary)]
        case .content: ["type": "string", "description": .string(summary.contains("Markdown") ? summary : "Текст Markdown")]
        case .int: ["type": "integer", "description": .string(summary)]
        case .number: ["type": "number", "description": .string(summary)]
        case .bool: ["type": "boolean", "description": .string(summary)]
        case .list: ["type": "array", "items": ["type": "string"], "description": .string(summary)]
        case .choice(let values): ["type": "string", "enum": .array(values.map { .string($0) }), "description": .string(summary)]
        case .json: ["description": .string(summary + " (значение JSON)")]
        case .jsonContent: ["type": "array", "items": ["type": "object"], "description": .string(summary.replacingOccurrences(of: ": файл или -", with: ""))]
        }
        guard argument.repeated, argument.type != .list else { return single }
        return ["type": "array", "items": single, "description": .string(summary)]
    }

    // MARK: - Аргументы от модели

    /// Модели шлют числа строкой, JSON — строкой, пустые необязательные — null. Приводим к тому, что ждёт каталог.
    private static func coerced(_ arguments: [String: ControlJSON], for spec: CommandSpec) -> [String: ControlJSON] {
        var result: [String: ControlJSON] = [:]
        for (key, value) in arguments {
            guard let argument = spec.argument(named: key) else {
                result[key] = value
                continue
            }
            switch (argument.type, value) {
            case (.json, .string(let text)), (.jsonContent, .string(let text)):
                result[key] = (try? ControlJSON(parsing: text)) ?? value
            case (.json, _):
                result[key] = value
            case (_, .null):
                continue
            case (.int, .string(let text)) where Int(text) != nil, (.number, .string(let text)) where Double(text) != nil:
                result[key] = .number(Double(text)!)
            case (.list, .array(let items)):
                // Ширины и прочие списки модель шлёт числами — каталог ждёт строки.
                result[key] = .array(items.map { item in item.number.map { .string(String(format: "%g", $0)) } ?? item })
            case (.bool, .string(let text)):
                result[key] = .bool(text == "true")
            case (.choice, .bool(let flag)) where argument.type == .onOff:
                result[key] = flag ? "on" : "off"
            default:
                result[key] = value
            }
        }
        return result
    }

    private static func truncated(_ text: String) -> String {
        guard text.count > maxOutputLength else { return text }
        return String(text.prefix(maxOutputLength)) + "\n…(ответ обрезан: \(text.count) знаков; сузь запрос)"
    }

    // MARK: - Подпись в ленте чата

    public static func title(for call: ModelToolCall) -> String {
        let arguments = (try? ControlJSON(parsing: call.arguments))?.object ?? [:]
        func page(_ prefix: String, _ key: String = "page", suffix: String = "") -> String {
            let value = arguments[key]?.string
            if value == "current" { return "\(prefix) открытую страницу\(suffix)" }
            guard let value, !value.isEmpty, UUID(uuidString: value) == nil else { return "\(prefix) страницу\(suffix)" }
            return "\(prefix) страницу «\(value)»\(suffix)"
        }
        func quoted(_ prefix: String, _ key: String) -> String {
            arguments[key]?.string.map { "\(prefix) «\($0)»" } ?? prefix
        }
        let command = specsByTool[call.name]?.name ?? call.name
        switch command {
        case "page.tree": return "Смотрит дерево страниц"
        case "page.get": return page("Смотрит")
        case "page.read": return page("Читает")
        case "page.create": return quoted("Создаёт страницу", "title")
        case "page.write": return page("Переписывает")
        case "page.append": return page("Дописывает")
        case "page.rename": return quoted("Переименовывает страницу в", "title")
        case "page.move": return page("Переносит")
        case "page.duplicate": return page("Копирует")
        case "page.trash": return page("Убирает", suffix: " в корзину")
        case "page.restore": return page("Возвращает", suffix: " из корзины")
        case "page.icon": return "Ставит иконку"
        case "page.layout": return "Меняет вид страницы"
        case "trash.list": return "Смотрит корзину"
        case "search": return quoted("Ищет", "query")
        case "recents": return "Смотрит недавние"
        case "open": return page("Открывает")
        case "block.insert": return "Вставляет блок"
        case "block.delete": return "Удаляет блок"
        case "block.table-widths": return "Подгоняет ширину столбцов"
        case "block.kinds", "block.get": return "Смотрит блоки"
        case "block.move", "block.move-to-page": return "Переносит блок"
        case "db.create": return "Создаёт базу"
        case "db.schema", "db.view.list", "db.template.list": return "Смотрит устройство базы"
        case "db.rows": return "Читает строки базы"
        case "db.row.add": return "Добавляет строки в базу"
        case "db.row.update", "db.cell.set": return "Правит строку базы"
        case "history.list", "history.show": return "Смотрит историю версий"
        case "history.restore": return "Восстанавливает версию"
        default:
            if command.hasPrefix("block.") { return "Правит блок" }
            if command.hasPrefix("db.") { return "Меняет базу" }
            return specsByTool[call.name]?.summary ?? call.name
        }
    }
}
