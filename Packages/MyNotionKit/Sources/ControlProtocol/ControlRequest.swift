import Foundation

/// Версия протокола: приложение отвечает `version_mismatch` на запрос другой версии.
public enum ControlProtocolVersion {
    public static let current = 1
    /// Имя агента без `--agent` и `MYNOTION_AGENT`.
    public static let defaultAgent = "агент"
    public static let defaultTimeoutMs = 30_000
    /// Импорт и выгрузка.
    public static let longTimeoutMs = 600_000
    /// Предел строки запроса и ответа.
    public static let maxFrameBytes = 64 * 1024 * 1024
}

/// Запрос команды (contracts/protocol.md, «Запрос»): одна строка JSON на подключение.
public struct ControlRequest: Sendable, Hashable, Codable {
    public var `protocol`: Int
    /// Любой текст клиента, возвращается в ответе.
    public var id: String
    /// `группа.действие` из каталога (`page.create`, `db.prop.add`).
    public var command: String
    public var args: [String: ControlJSON]
    public var agent: String
    public var timeoutMs: Int
    /// Папка клиента: относительные пути файлов считаются от неё.
    public var cwd: String?
    /// `--human`: приложение добавляет в ответ строку `text` для человека.
    public var human: Bool

    public init(protocol: Int = ControlProtocolVersion.current, id: String = UUID().uuidString.lowercased(), command: String,
                args: [String: ControlJSON] = [:], agent: String = ControlProtocolVersion.defaultAgent,
                timeoutMs: Int = ControlProtocolVersion.defaultTimeoutMs, cwd: String? = nil, human: Bool = false) {
        self.protocol = `protocol`
        self.id = id
        self.command = command
        self.args = args
        self.agent = agent
        self.timeoutMs = timeoutMs
        self.cwd = cwd
        self.human = human
    }

    private enum CodingKeys: String, CodingKey {
        case `protocol`, id, command, args, agent, timeoutMs, cwd, human
    }

    /// Пропущенное — по умолчанию: запрос мог собрать агент руками.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        `protocol` = try container.decode(Int.self, forKey: .protocol)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        command = try container.decode(String.self, forKey: .command)
        args = try container.decodeIfPresent([String: ControlJSON].self, forKey: .args) ?? [:]
        agent = try container.decodeIfPresent(String.self, forKey: .agent) ?? ControlProtocolVersion.defaultAgent
        timeoutMs = try container.decodeIfPresent(Int.self, forKey: .timeoutMs) ?? ControlProtocolVersion.defaultTimeoutMs
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        human = try container.decodeIfPresent(Bool.self, forKey: .human) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(`protocol`, forKey: .protocol)
        try container.encode(id, forKey: .id)
        try container.encode(command, forKey: .command)
        try container.encode(args, forKey: .args)
        try container.encode(agent, forKey: .agent)
        try container.encode(timeoutMs, forKey: .timeoutMs)
        try container.encodeIfPresent(cwd, forKey: .cwd)
        if human { try container.encode(true, forKey: .human) }
    }
}
