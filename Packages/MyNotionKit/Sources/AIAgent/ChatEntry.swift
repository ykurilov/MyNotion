import AIModels
import Foundation

/// Страница, открытая у человека в момент сообщения. Хранится вместе с сообщением: запрос к модели при следующем ходе
/// собирается из тех же байтов, и поставщик берёт начало из кэша.
public struct PageContext: Sendable, Hashable, Codable {
    public var pageID: String
    public var title: String
    public var path: String
    public var markdown: String
    /// Текст страницы длиннее предела и обрезан.
    public var truncated: Bool
    /// Та же страница с тем же текстом, что у прошлого сообщения: текст не повторяется.
    public var unchanged: Bool

    public init(pageID: String, title: String, path: String, markdown: String, truncated: Bool, unchanged: Bool = false) {
        self.pageID = pageID
        self.title = title
        self.path = path
        self.markdown = markdown
        self.truncated = truncated
        self.unchanged = unchanged
    }
}

public struct ToolOutcome: Sendable, Hashable {
    public var ok: Bool
    /// Текст для модели: данные ответа команды или ошибка с подсказкой.
    public var output: String

    public init(ok: Bool, output: String) {
        self.ok = ok
        self.output = output
    }
}

/// Запись чата: сообщение человека, ответ модели или результат инструмента. Поля по видам необязательны:
/// так запись нового MyNotion читает и старый, а неизвестные поля пропускаются.
public struct ChatEntry: Sendable, Hashable, Codable, Identifiable {
    public enum Kind: String, Sendable, Hashable, Codable { case user, assistant, tool }

    public var id: UUID
    public var createdAt: Date
    public var kind: Kind
    /// Сообщение человека, текст ответа или вывод инструмента для модели.
    public var text: String
    public var page: PageContext?
    public var reasoning: String?
    public var toolCalls: [ModelToolCall]?
    public var modelID: String?
    public var provider: ModelProvider?
    public var usage: ModelUsage?
    /// Ответ сорвался: фраза для человека.
    public var error: String?
    public var stopped: Bool?
    public var callID: String?
    public var toolName: String?
    /// Подпись вызова в ленте: «Читает страницу «План»».
    public var title: String?
    public var ok: Bool?
    /// Пометка под ответом: почему он пришёл запасным путём.
    public var notice: String?

    public init(id: UUID = UUID(), createdAt: Date = Date(), kind: Kind, text: String = "") {
        self.id = id
        self.createdAt = createdAt
        self.kind = kind
        self.text = text
    }

    public static func user(_ text: String, page: PageContext?, id: UUID = UUID(), at date: Date = Date()) -> ChatEntry {
        var entry = ChatEntry(id: id, createdAt: date, kind: .user, text: text)
        entry.page = page
        return entry
    }

    public static func assistant(turn: ModelTurn, modelID: String, id: UUID = UUID(), at date: Date = Date()) -> ChatEntry {
        var entry = ChatEntry(id: id, createdAt: date, kind: .assistant, text: turn.text)
        entry.reasoning = turn.reasoning.isEmpty ? nil : turn.reasoning
        entry.toolCalls = turn.toolCalls.isEmpty ? nil : turn.toolCalls
        entry.modelID = modelID
        entry.provider = turn.route?.provider
        entry.usage = turn.usage
        entry.notice = turn.notice
        return entry
    }

    /// Ответ, который сорвался или остановлен: что успело прийти, без вызовов — они не выполнялись.
    public static func failedAssistant(turn: ModelTurn = ModelTurn(), error: String?, stopped: Bool = false, modelID: String,
                                       id: UUID = UUID(), at date: Date = Date()) -> ChatEntry {
        var entry = assistant(turn: turn, modelID: modelID, id: id, at: date)
        entry.toolCalls = nil
        entry.error = error
        entry.stopped = stopped ? true : nil
        return entry
    }

    public static func tool(callID: String, name: String, outcome: ToolOutcome, title: String, id: UUID = UUID(),
                            at date: Date = Date()) -> ChatEntry {
        var entry = ChatEntry(id: id, createdAt: date, kind: .tool, text: outcome.output)
        entry.callID = callID
        entry.toolName = name
        entry.title = title
        entry.ok = outcome.ok
        return entry
    }
}
