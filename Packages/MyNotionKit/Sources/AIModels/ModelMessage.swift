import ControlProtocol
import Foundation

/// Вызов инструмента в ответе модели. `arguments` — текст JSON, как его прислала модель.
public struct ModelToolCall: Sendable, Hashable, Codable {
    public var id: String
    public var name: String
    public var arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

/// Сообщение запроса в общем виде; поставщику его переводит `ChatCompletionBody`.
public struct ModelMessage: Sendable, Hashable {
    public enum Role: String, Sendable, Hashable { case system, user, assistant, tool }

    public var role: Role
    public var content: String
    /// Рассуждения ответа: DeepSeek требует вернуть их в ходе с инструментами.
    public var reasoning: String?
    public var toolCalls: [ModelToolCall]
    public var toolCallID: String?

    public static func system(_ text: String) -> ModelMessage {
        ModelMessage(role: .system, content: text, reasoning: nil, toolCalls: [], toolCallID: nil)
    }

    public static func user(_ text: String) -> ModelMessage {
        ModelMessage(role: .user, content: text, reasoning: nil, toolCalls: [], toolCallID: nil)
    }

    public static func assistant(text: String, reasoning: String?, toolCalls: [ModelToolCall]) -> ModelMessage {
        ModelMessage(role: .assistant, content: text, reasoning: reasoning, toolCalls: toolCalls, toolCallID: nil)
    }

    public static func tool(callID: String, content: String) -> ModelMessage {
        ModelMessage(role: .tool, content: content, reasoning: nil, toolCalls: [], toolCallID: callID)
    }
}

/// Инструмент для модели: имя, описание и схема аргументов JSON Schema.
public struct ModelTool: Sendable, Hashable {
    public var name: String
    public var description: String
    public var parameters: ControlJSON

    public init(name: String, description: String, parameters: ControlJSON) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

public struct ModelRequest: Sendable, Hashable {
    public var messages: [ModelMessage]
    public var tools: [ModelTool]
    public var level: ReasoningLevel

    public init(messages: [ModelMessage], tools: [ModelTool], level: ReasoningLevel) {
        self.messages = messages
        self.tools = tools
        self.level = level
    }
}
