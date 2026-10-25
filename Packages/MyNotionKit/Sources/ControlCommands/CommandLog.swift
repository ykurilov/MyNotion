import ControlProtocol
import Foundation
import os

/// Строка журнала на команду (research R11): имя, указатель, итог или код ошибки, длительность, агент. Текста записей нет.
public struct CommandLogEntry: Sendable, Hashable {
    public var command: String
    public var agent: String
    /// Указатель страницы или блока из аргументов (id, путь) — не содержимое.
    public var target: String?
    public var errorCode: ControlErrorCode?
    public var durationMs: Int

    public init(command: String, agent: String, target: String?, errorCode: ControlErrorCode?, durationMs: Int) {
        self.command = command
        self.agent = agent
        self.target = target
        self.errorCode = errorCode
        self.durationMs = durationMs
    }

    public var line: String {
        "\(command)" + (target.map { " \($0)" } ?? "") + " → " + (errorCode?.rawValue ?? "ok") + " \(durationMs) мс, агент \(agent)"
    }

    /// Аргументы-указатели, которые можно писать в журнал.
    static let targetKeys = ["page", "block", "database", "row", "view", "property", "version", "attachment"]

    static func target(of args: [String: ControlJSON]) -> String? {
        let parts = targetKeys.compactMap { key in args[key]?.string.map { "\(key)=\($0)" } }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

public protocol CommandLogging: Sendable {
    func record(_ entry: CommandLogEntry)
}

/// Журнал системы: `log show --predicate 'category == "control"'`.
public struct CommandLog: CommandLogging {
    private static let logger = Logger(subsystem: "cloud.kurilov.mynotion", category: "control")

    public init() {}

    public func record(_ entry: CommandLogEntry) {
        let line = entry.line
        if entry.errorCode == nil {
            Self.logger.info("\(line, privacy: .public)")
        } else {
            Self.logger.notice("\(line, privacy: .public)")
        }
    }
}
