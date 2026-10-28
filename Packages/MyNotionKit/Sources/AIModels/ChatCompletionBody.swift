import ControlProtocol
import Foundation

/// Тело запроса в формате OpenAI Chat Completions — у DeepSeek и OpenRouter свои поля рассуждений.
/// Ключи по алфавиту: одинаковое начало чата даёт одинаковые байты, поставщик берёт его из кэша.
public enum ChatCompletionBody {
    public static func json(for request: ModelRequest, route: ModelRoute) -> ControlJSON {
        let thinking = route.reasoning == .deepSeekThinking && request.level != .none
        var body: [String: ControlJSON] = [
            "model": .string(route.modelID),
            "messages": .array(request.messages.map { message(for: $0, provider: route.provider, thinking: thinking) }),
            "stream": true,
            "stream_options": ["include_usage": true],
        ]
        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools.map { tool in
                ["type": "function", "function": ["name": .string(tool.name), "description": .string(tool.description),
                                                  "parameters": tool.parameters]]
            })
        }
        switch route.reasoning {
        case .deepSeekThinking:
            if request.level == .none {
                body["thinking"] = ["type": "disabled"]
            } else {
                body["thinking"] = ["type": "enabled"]
                body["reasoning_effort"] = .string(request.level == .medium ? "high" : request.level.rawValue)
            }
        case .effort:
            switch request.level {
            case .none: body["reasoning"] = ["enabled": false]
            case .max: body["reasoning"] = ["effort": "xhigh"]
            default: body["reasoning"] = ["effort": .string(request.level.rawValue)]
            }
        case .toggle:
            body["reasoning"] = ["enabled": .bool(request.level != .none)]
        }
        return .object(body)
    }

    public static func data(for request: ModelRequest, route: ModelRoute) -> Data {
        Data(json(for: request, route: route).encodedText().utf8)
    }

    /// `thinking` — DeepSeek с рассуждениями: он требует `reasoning_content` у каждого хода с инструментами, даже если
    /// тот шёл без рассуждений (на уровне «Без рассуждений» или через OpenRouter), иначе отвечает 400.
    private static func message(for message: ModelMessage, provider: ModelProvider, thinking: Bool) -> ControlJSON {
        var fields: [String: ControlJSON] = ["role": .string(message.role.rawValue)]
        switch message.role {
        case .system, .user:
            fields["content"] = .string(message.content)
        case .tool:
            fields["content"] = .string(message.content)
            fields["tool_call_id"] = ControlJSON(message.toolCallID)
        case .assistant:
            fields["content"] = message.content.isEmpty && !message.toolCalls.isEmpty ? .null : .string(message.content)
            if let reasoning = message.reasoning, !reasoning.isEmpty {
                fields[provider == .deepSeek ? "reasoning_content" : "reasoning"] = .string(reasoning)
            } else if thinking, !message.toolCalls.isEmpty {
                fields["reasoning_content"] = ""
            }
            if !message.toolCalls.isEmpty {
                fields["tool_calls"] = .array(message.toolCalls.map { call in
                    ["id": .string(call.id), "type": "function", "function": ["name": .string(call.name), "arguments": .string(call.arguments)]]
                })
            }
        }
        return .object(fields)
    }
}
