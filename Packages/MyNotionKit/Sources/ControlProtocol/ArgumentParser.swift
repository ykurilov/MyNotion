import Foundation

/// Общие флаги (contracts/protocol.md, «Общие флаги»): понимаются в любом месте строки.
public enum GlobalFlag: String, Sendable, CaseIterable {
    case human
    case agent
    case timeout
    case noLaunch = "no-launch"
    case launchTimeout = "launch-timeout"
    case socket
    case includeTrashed = "include-trashed"
    case limit
    case cursor
    case help
    case version

    var takesValue: Bool {
        switch self {
        case .agent, .timeout, .launchTimeout, .socket, .limit, .cursor: true
        case .human, .noLaunch, .includeTrashed, .help, .version: false
        }
    }

    var summary: String {
        switch self {
        case .human: "Кратко для человека вместо JSON"
        case .agent: "Имя агента в истории версий (или MYNOTION_AGENT)"
        case .timeout: "Срок ответа, мс (30 000; импорт и выгрузка — 600 000)"
        case .noLaunch: "Не запускать приложение, если оно закрыто"
        case .launchTimeout: "Сколько ждать запуска приложения, с (15)"
        case .socket: "Другой сокет (или MYNOTION_SOCKET)"
        case .includeTrashed: "Видеть страницы в корзине"
        case .limit: "Сколько записей списка (200, не больше 1 000)"
        case .cursor: "Следующая часть списка: nextCursor прошлого ответа"
        case .help: "Справка"
        case .version: "Версия команды и приложения"
        }
    }
}

/// Настройки самого клиента: до приложения не доходят.
public struct ClientSettings: Sendable, Hashable {
    public var human = false
    public var noLaunch = false
    /// Секунды.
    public var launchTimeout: Double = 15
    public var socketPath: String?

    public init(human: Bool = false, noLaunch: Bool = false, launchTimeout: Double = 15, socketPath: String? = nil) {
        self.human = human
        self.noLaunch = noLaunch
        self.launchTimeout = launchTimeout
        self.socketPath = socketPath
    }
}

/// Что делать по строке команды.
public enum Invocation: Sendable, Hashable {
    /// Справка — без приложения.
    case help(String)
    case version(ClientSettings)
    case request(ControlRequest, ClientSettings, CommandSpec)
}

extension CommandCatalog {
    /// Разобрать строку команды (без имени программы). `readContent("-")` — stdin, иначе путь файла: содержимое
    /// `--markdown`, `--file` клиент читает сам.
    public static func parse(_ argv: [String], environment: [String: String] = [:], currentDirectory: String? = nil,
                             readContent: (String) throws -> String = { _ in "" }) throws(ControlError) -> Invocation {
        var settings = ClientSettings(socketPath: environment["MYNOTION_SOCKET"].flatMap { $0.isEmpty ? nil : $0 })
        var agent = environment["MYNOTION_AGENT"].flatMap { $0.isEmpty ? nil : $0 } ?? ControlProtocolVersion.defaultAgent
        var timeoutMs: Int?
        var shared: [String: ControlJSON] = [:]
        var wantsHelp = false, wantsVersion = false
        var rest: [String] = []

        var index = 0
        while index < argv.count {
            let token = argv[index]
            index += 1
            if token == "-h" { wantsHelp = true; continue }
            guard token.hasPrefix("--"), token.count > 2 else { rest.append(token); continue }
            let (name, inline) = splitFlag(token)
            guard let flag = GlobalFlag(rawValue: name) else { rest.append(token); continue }
            var value: String?
            if flag.takesValue {
                if let inline { value = inline } else if index < argv.count { value = argv[index]; index += 1 }
                if value == nil {
                    throw ControlError(.missingArgument, "У флага --\(name) нет значения", hint: "Пример: --\(name) <значение>")
                }
            }
            switch flag {
            case .human: settings.human = true
            case .noLaunch: settings.noLaunch = true
            case .includeTrashed: shared["includeTrashed"] = true
            case .help: wantsHelp = true
            case .version: wantsVersion = true
            case .agent: agent = value ?? agent
            case .socket: settings.socketPath = value
            case .cursor: shared["cursor"] = value.map(ControlJSON.string)
            case .timeout:
                guard let ms = value.flatMap(Int.init), ms > 0 else { throw ControlError(.invalidValue, "--timeout — миллисекунды, целое больше нуля") }
                timeoutMs = ms
            case .launchTimeout:
                guard let seconds = value.flatMap(Double.init), seconds >= 0 else {
                    throw ControlError(.invalidValue, "--launch-timeout — секунды, число не меньше нуля")
                }
                settings.launchTimeout = seconds
            case .limit:
                guard let limit = value.flatMap(Int.init) else { throw ControlError(.invalidValue, "--limit — целое число") }
                shared["limit"] = .number(Double(limit))
            }
        }

        // Слова команды — сколько совпадает с началом какой-нибудь команды каталога.
        var words: [String] = []
        while words.count < rest.count, !rest[words.count].hasPrefix("-"),
              all.contains(where: { $0.words.starts(with: words + [rest[words.count]]) }) {
            words.append(rest[words.count])
        }
        let tokens = Array(rest[words.count...])

        if wantsVersion, words.isEmpty { return .version(settings) }
        if words.isEmpty {
            if let first = tokens.first, !wantsHelp {
                throw unknownCommand([first])
            }
            return .help(CommandHelp.top())
        }
        guard let spec = spec(words: words) else {
            if let next = tokens.first, !next.hasPrefix("-"), !wantsHelp { throw unknownCommand(words + [next]) }
            return .help(CommandHelp.group(words))
        }
        if wantsHelp { return .help(CommandHelp.command(spec)) }

        var args = try ArgumentParser.parse(tokens, for: spec, readContent: readContent)
        args.merge(shared) { own, _ in own }
        args = try normalized(args, for: spec)
        let request = ControlRequest(command: spec.name, args: args, agent: agent,
                                     timeoutMs: timeoutMs ?? (spec.isLong ? ControlProtocolVersion.longTimeoutMs : ControlProtocolVersion.defaultTimeoutMs),
                                     cwd: currentDirectory, human: settings.human)
        return .request(request, settings, spec)
    }

    static func unknownCommand(_ words: [String]) -> ControlError {
        let typed = words.joined(separator: " ")
        let near = suggestion(for: words)
        return ControlError(.unknownCommand, "Нет команды «\(typed)»",
                            hint: near.map { "Похоже на: mynotion \($0.invocation)" } ?? "Список команд: mynotion --help",
                            details: near.map { ["suggestion": .string($0.invocation)] })
    }

    static func splitFlag(_ token: String) -> (name: String, value: String?) {
        let body = token.dropFirst(2)
        guard let equals = body.firstIndex(of: "=") else { return (String(body), nil) }
        return (String(body[..<equals]), String(body[body.index(after: equals)...]))
    }
}

/// Разбор аргументов одной команды по её описанию: позиционные по порядку, флаги `--флаг значение` и `--флаг=значение`.
public enum ArgumentParser {
    public static func parse(_ tokens: [String], for spec: CommandSpec,
                             readContent: (String) throws -> String) throws(ControlError) -> [String: ControlJSON] {
        var args: [String: ControlJSON] = [:]
        let positionals = spec.positionals
        var positionalIndex = 0
        var onlyPositionals = false
        var index = 0

        func addPositional(_ token: String) throws(ControlError) {
            guard positionalIndex < positionals.count else {
                throw ControlError(.invalidArgument, "Лишний аргумент «\(token)»", hint: "Использование: mynotion \(spec.usage)",
                                   details: ["argument": .string(token)])
            }
            let argument = positionals[positionalIndex]
            let value = try convert(token, argument, spec, readContent)
            if argument.repeated {
                args[argument.name] = .array((args[argument.name]?.array ?? []) + [value])
            } else {
                args[argument.name] = value
                positionalIndex += 1
            }
        }

        while index < tokens.count {
            let token = tokens[index]
            index += 1
            if onlyPositionals || !token.hasPrefix("--") || token == "--" {
                if token == "--", !onlyPositionals { onlyPositionals = true; continue }
                try addPositional(token)
                continue
            }
            let (name, inline) = CommandCatalog.splitFlag(token)
            guard let argument = spec.flags.first(where: { $0.flag == name }) else {
                let near = spec.flags.compactMap(\.flag).min { EditDistance.between(name, $0) < EditDistance.between(name, $1) }
                let close = near.flatMap { EditDistance.between(name, $0) <= max(2, name.count / 3) ? $0 : nil }
                throw ControlError(.invalidArgument, "У команды «\(spec.invocation)» нет флага --\(name)",
                                   hint: close.map { "Похоже на --\($0)" } ?? "Справка: mynotion \(spec.invocation) --help",
                                   details: .object(["flag": .string("--" + name)].merging(close.map { ["suggestion": ControlJSON.string("--" + $0)] } ?? [:]) { a, _ in a }))
            }
            if argument.type == .bool {
                if let inline {
                    guard let flag = ["true": true, "on": true, "yes": true, "false": false, "off": false, "no": false][inline.lowercased()] else {
                        throw ControlError(.invalidValue, "--\(name) — флаг без значения")
                    }
                    args[argument.name] = .bool(flag)
                } else {
                    args[argument.name] = true
                }
                continue
            }
            var raw: [String] = []
            if let inline {
                raw = [inline]
            } else if index < tokens.count {
                raw = [tokens[index]]
                index += 1
            } else {
                throw ControlError(.missingArgument, "У флага --\(name) нет значения", hint: "Использование: mynotion \(spec.usage)",
                                   details: ["argument": .string(argument.name)])
            }
            if argument.repeated {
                // `--to a b c`: значения подряд до следующего флага.
                while index < tokens.count, !tokens[index].hasPrefix("-") {
                    raw.append(tokens[index])
                    index += 1
                }
                var values = args[argument.name]?.array ?? []
                for text in raw { values.append(try convert(text, argument, spec, readContent)) }
                args[argument.name] = .array(values)
            } else {
                guard args[argument.name] == nil else {
                    throw ControlError(.invalidArgument, "Флаг --\(name) указан дважды", hint: "Оставьте одно значение",
                                       details: ["argument": .string(argument.name)])
                }
                args[argument.name] = try convert(raw[0], argument, spec, readContent)
            }
        }

        // Пропущенный `--file` пакета — stdin: значение по умолчанию `-` у содержимого читается здесь.
        for argument in spec.arguments where args[argument.name] == nil {
            if let fallback = argument.defaultValue?.string, argument.type == .content || argument.type == .jsonContent {
                args[argument.name] = try convert(fallback, argument, spec, readContent)
            }
        }
        return args
    }

    static func convert(_ text: String, _ argument: ArgumentSpec, _ spec: CommandSpec,
                        _ readContent: (String) throws -> String) throws(ControlError) -> ControlJSON {
        func invalid(_ expected: String, allowed: [String]? = nil) -> ControlError {
            var details: [String: ControlJSON] = ["argument": .string(argument.name), "expected": .string(expected), "value": .string(text)]
            if let allowed { details["allowed"] = .array(allowed.map { .string($0) }) }
            return ControlError(.invalidValue, "Неверное значение \(spec.label(of: argument.name)): «\(text)», нужно \(expected)",
                                hint: "Пример: \(spec.example)", details: .object(details))
        }
        switch argument.type {
        case .page, .block, .database, .property, .view, .option, .row, .version, .attachment, .string, .path:
            return .string(text)
        case .int:
            guard let value = Int(text) else { throw invalid("целое число") }
            return .number(Double(value))
        case .number:
            guard let value = Double(text.replacingOccurrences(of: ",", with: ".")) else { throw invalid("число") }
            return .number(value)
        case .json:
            do { return try ControlJSON(parsing: text) } catch { throw invalid("JSON") }
        case .bool:
            return true
        case .list:
            return .array(text.split(separator: ",").map { .string($0.trimmingCharacters(in: .whitespaces)) })
        case .choice(let values):
            guard values.contains(text) else { throw invalid(values.joined(separator: "|"), allowed: values) }
            return .string(text)
        case .content, .jsonContent:
            let content: String
            do {
                content = try readContent(text)
            } catch {
                throw ControlError(.fileNotFound, "Не прочитать «\(text)»: \(error.localizedDescription)",
                                   hint: "Путь к файлу или - для stdin", details: ["argument": .string(argument.name), "path": .string(text)])
            }
            guard argument.type == .jsonContent else { return .string(content) }
            do { return try ControlJSON(parsing: content) } catch { throw invalid("JSON") }
        }
    }
}
