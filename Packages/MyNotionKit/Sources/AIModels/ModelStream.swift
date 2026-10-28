import ControlProtocol
import Foundation

public struct ModelUsage: Sendable, Hashable, Codable {
    public var promptTokens: Int
    public var completionTokens: Int
    /// Сколько начала запроса поставщик взял из кэша.
    public var cachedPromptTokens: Int

    public init(promptTokens: Int, completionTokens: Int, cachedPromptTokens: Int) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.cachedPromptTokens = cachedPromptTokens
    }
}

/// Кусочек вызова инструмента: модель шлёт имя и аргументы частями под одним `index`.
public struct ToolCallDelta: Sendable, Hashable {
    public var index: Int
    public var id: String?
    public var name: String?
    public var arguments: String

    public init(index: Int, id: String?, name: String?, arguments: String) {
        self.index = index
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

public enum ModelStreamEvent: Sendable, Hashable {
    /// Каким путём идёт ответ — первым событием.
    case route(ModelRoute)
    case reasoning(String)
    case text(String)
    case toolCall(ToolCallDelta)
    case usage(ModelUsage)
    case finished(String?)

    /// Модель начала отвечать: после этого запасной путь уже не пробуют.
    var isContent: Bool {
        switch self {
        case .reasoning, .text, .toolCall: true
        case .route, .usage, .finished: false
        }
    }
}

/// Строка потока SSE → события. Каждое событие OpenAI-совместимого потока — одна строка `data: {…}`.
public enum StreamChunkDecoder {
    public enum Line: Sendable, Hashable {
        case events([ModelStreamEvent])
        case done
    }

    public static func decode(line: String, provider: ModelProvider = .deepSeek) throws -> Line {
        guard line.hasPrefix("data:") else {
            // Ошибка бывает и голым JSON при ответе 200 — без неё ход кончился бы пустым ответом.
            let bare = line.trimmingCharacters(in: .whitespaces)
            if bare.hasPrefix("{"), let error = (try? ControlJSON(parsing: bare))?["error"], error.object != nil {
                throw ModelError.streamError(error, provider: provider)
            }
            return .events([])
        }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return .done }
        guard let chunk = try? ControlJSON(parsing: payload), chunk.object != nil else { throw ModelError.badResponse }
        if let error = chunk["error"], error.object != nil { throw ModelError.streamError(error, provider: provider) }

        var events: [ModelStreamEvent] = []
        if let choice = chunk["choices"]?[0] {
            let delta = choice["delta"]
            if let reasoning = delta?["reasoning_content"]?.string ?? delta?["reasoning"]?.string, !reasoning.isEmpty {
                events.append(.reasoning(reasoning))
            }
            if let text = delta?["content"]?.string, !text.isEmpty { events.append(.text(text)) }
            for call in delta?["tool_calls"]?.array ?? [] {
                events.append(.toolCall(ToolCallDelta(index: call["index"]?.int ?? 0, id: call["id"]?.string,
                                                      name: call["function"]?["name"]?.string,
                                                      arguments: call["function"]?["arguments"]?.string ?? "")))
            }
            if let reason = choice["finish_reason"]?.string { events.append(.finished(reason)) }
        }
        if let usage = chunk["usage"], usage.object != nil {
            events.append(.usage(ModelUsage(
                promptTokens: usage["prompt_tokens"]?.int ?? 0, completionTokens: usage["completion_tokens"]?.int ?? 0,
                cachedPromptTokens: usage["prompt_cache_hit_tokens"]?.int ?? usage["prompt_tokens_details"]?["cached_tokens"]?.int ?? 0)))
        }
        return .events(events)
    }
}

/// Ответ модели целиком, собранный из событий потока.
public struct ModelTurn: Sendable, Hashable {
    public var route: ModelRoute?
    public var reasoning = ""
    public var text = ""
    public var usage: ModelUsage?
    public var finishReason: String?

    private var calls: [ModelToolCall] = []
    private var callPositions: [Int: Int] = [:]
    /// Основа своих id для вызовов, которым поставщик id не дал: одинаковых от чтения к чтению.
    private let callIDSeed = UUID().uuidString.prefix(8).lowercased()

    public init() {}

    /// Вызовы с пустыми аргументами — как `{}`: так их понимают все поставщики. Вызов без id — со своим.
    public var toolCalls: [ModelToolCall] {
        calls.enumerated().map { position, call in
            var call = call
            if call.arguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { call.arguments = "{}" }
            if call.id.isEmpty { call.id = "call_\(callIDSeed)_\(position)" }
            return call
        }
    }

    public mutating func apply(_ event: ModelStreamEvent) {
        switch event {
        case .route(let route): self.route = route
        case .reasoning(let part): reasoning += part
        case .text(let part): text += part
        case .usage(let usage): self.usage = usage
        case .finished(let reason): finishReason = reason
        case .toolCall(let delta): applyToolCall(delta)
        }
    }

    /// Части вызова склеиваются по `index`. Часть поставщиков шлёт параллельные вызовы под одним `index` с разными id,
    /// а имя — целиком в каждой части: новый id начинает новый вызов, полное имя не дописывается к себе же.
    private mutating func applyToolCall(_ delta: ToolCallDelta) {
        let id = delta.id ?? ""
        guard let position = callPositions[delta.index], id.isEmpty || calls[position].id.isEmpty || calls[position].id == id else {
            callPositions[delta.index] = calls.count
            calls.append(ModelToolCall(id: id, name: delta.name ?? "", arguments: delta.arguments))
            return
        }
        if !id.isEmpty { calls[position].id = id }
        if let name = delta.name, !name.isEmpty {
            calls[position].name = name.hasPrefix(calls[position].name) ? name : calls[position].name + name
        }
        calls[position].arguments += delta.arguments
    }
}
