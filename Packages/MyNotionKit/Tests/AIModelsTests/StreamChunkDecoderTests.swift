import Testing
@testable import AIModels

@Suite("Разбор потока ответа")
struct StreamChunkDecoderTests {
    private func events(_ line: String) throws -> [ModelStreamEvent] {
        guard case .events(let events) = try StreamChunkDecoder.decode(line: line) else { return [] }
        return events
    }

    @Test("Пустые строки, комментарии и [DONE]")
    func serviceLines() throws {
        #expect(try StreamChunkDecoder.decode(line: "") == .events([]))
        #expect(try StreamChunkDecoder.decode(line: ": OPENROUTER PROCESSING") == .events([]))
        #expect(try StreamChunkDecoder.decode(line: "event: ping") == .events([]))
        #expect(try StreamChunkDecoder.decode(line: "data: [DONE]") == .done)
    }

    @Test("Текст и рассуждения DeepSeek (reasoning_content) и OpenRouter (reasoning) без задвоения")
    func deltas() throws {
        #expect(try events(#"data: {"choices":[{"index":0,"delta":{"content":"При"}}]}"#) == [.text("При")])
        #expect(try events(#"data: {"choices":[{"delta":{"reasoning_content":"Думаю"}}]}"#) == [.reasoning("Думаю")])
        #expect(try events(#"data: {"choices":[{"delta":{"reasoning":"Мысль"}}]}"#) == [.reasoning("Мысль")])
        #expect(try events(#"data: {"choices":[{"delta":{"reasoning":"x","reasoning_content":"x"}}]}"#) == [.reasoning("x")])
        #expect(try events(#"data: {"choices":[{"delta":{"content":"","reasoning":null}}]}"#) == [])
    }

    @Test("Части вызова инструмента и причина конца")
    func toolCalls() throws {
        let start = #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"page_read","arguments":""}}]}}]}"#
        #expect(try events(start) == [.toolCall(ToolCallDelta(index: 0, id: "call_1", name: "page_read", arguments: ""))])
        let part = #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"page\""}}]}}]}"#
        #expect(try events(part) == [.toolCall(ToolCallDelta(index: 0, id: nil, name: nil, arguments: #"{"page""#))])
        #expect(try events(#"data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#) == [.finished("tool_calls")])
    }

    @Test("Расход: попадания в кэш DeepSeek и OpenRouter")
    func usage() throws {
        let deepSeek = #"data: {"choices":[],"usage":{"prompt_tokens":1200,"completion_tokens":40,"prompt_cache_hit_tokens":1024}}"#
        #expect(try events(deepSeek) == [.usage(ModelUsage(promptTokens: 1200, completionTokens: 40, cachedPromptTokens: 1024))])
        let openRouter = #"data: {"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":900,"completion_tokens":5,"prompt_tokens_details":{"cached_tokens":512}}}"#
        #expect(try events(openRouter) == [.finished("stop"), .usage(ModelUsage(promptTokens: 900, completionTokens: 5, cachedPromptTokens: 512))])
    }

    @Test("Ошибка посреди потока: 5xx и 429 — сбой сервера, остальное — текст ошибки")
    func streamErrors() {
        #expect(throws: ModelError.server(.openRouter, 502)) {
            try StreamChunkDecoder.decode(line: #"data: {"error":{"code":502,"message":"Provider returned error"}}"#, provider: .openRouter)
        }
        #expect(throws: ModelError.rateLimited(.openRouter)) {
            try StreamChunkDecoder.decode(line: #"data: {"error":{"code":429,"message":"slow down"}}"#, provider: .openRouter)
        }
        #expect(throws: ModelError.provider("Context too long")) {
            try StreamChunkDecoder.decode(line: #"data: {"error":{"code":400,"message":"Context too long"}}"#, provider: .openRouter)
        }
        #expect(throws: ModelError.badResponse) { try StreamChunkDecoder.decode(line: "data: {не json") }
    }

    @Test("Ошибка JSON-телом без data: при ответе 200 — ошибка, а не пустой ответ")
    func bareErrorBody() {
        #expect(throws: ModelError.provider("Model is overloaded")) {
            try StreamChunkDecoder.decode(line: #"{"error":{"code":400,"message":"Model is overloaded"}}"#, provider: .openRouter)
        }
        #expect(throws: ModelError.server(.deepSeek, 503)) {
            try StreamChunkDecoder.decode(line: #"  {"error":{"code":503,"message":"busy"}}"#, provider: .deepSeek)
        }
    }
}

@Suite("Сборка ответа модели")
struct ModelTurnTests {
    @Test("Части текста, рассуждений и вызовов складываются; маршрут и расход запоминаются")
    func accumulate() {
        var turn = ModelTurn()
        let route = ModelCatalog.glmFlash.routes[0]
        for event: ModelStreamEvent in [.route(route), .reasoning("Ду"), .reasoning("маю"), .text("Го"), .text("тово"),
                                        .toolCall(ToolCallDelta(index: 0, id: "a", name: "page_read", arguments: #"{"pa"#)),
                                        .toolCall(ToolCallDelta(index: 1, id: "b", name: "search", arguments: "{}")),
                                        .toolCall(ToolCallDelta(index: 0, id: nil, name: nil, arguments: #"ge":"x"}"#)),
                                        .finished("tool_calls"), .usage(ModelUsage(promptTokens: 10, completionTokens: 2, cachedPromptTokens: 0))] {
            turn.apply(event)
        }
        #expect(turn.route == route)
        #expect(turn.reasoning == "Думаю")
        #expect(turn.text == "Готово")
        #expect(turn.toolCalls == [ModelToolCall(id: "a", name: "page_read", arguments: #"{"page":"x"}"#),
                                   ModelToolCall(id: "b", name: "search", arguments: "{}")])
        #expect(turn.finishReason == "tool_calls")
        #expect(turn.usage?.promptTokens == 10)
    }

    @Test("Параллельные вызовы под одним index с разными id — два вызова; имя, повторённое в каждом кусочке, не двоится")
    func sameIndexCalls() {
        var turn = ModelTurn()
        for delta in [ToolCallDelta(index: 0, id: "a", name: "page_read", arguments: #"{"page":"#),
                      ToolCallDelta(index: 0, id: "a", name: "page_read", arguments: #""x"}"#),
                      ToolCallDelta(index: 0, id: "b", name: "search", arguments: #"{"query":"y"}"#),
                      ToolCallDelta(index: 1, id: nil, name: "page_", arguments: ""),
                      ToolCallDelta(index: 1, id: nil, name: "tree", arguments: "")] {
            turn.apply(.toolCall(delta))
        }
        #expect(turn.toolCalls.map(\.name) == ["page_read", "search", "page_tree"])
        #expect(turn.toolCalls.map(\.arguments) == [#"{"page":"x"}"#, #"{"query":"y"}"#, "{}"])
        #expect(turn.toolCalls.prefix(2).map(\.id) == ["a", "b"])
        #expect(!turn.toolCalls[2].id.isEmpty)
    }

    @Test("Вызов без id получает свой id, а id из следующего кусочка заменяет его, не начиная новый вызов")
    func lateID() {
        var turn = ModelTurn()
        turn.apply(.toolCall(ToolCallDelta(index: 0, id: nil, name: "page_read", arguments: "{")))
        let generated = turn.toolCalls.first?.id
        #expect(generated == turn.toolCalls.first?.id, "Свой id не меняется от чтения к чтению")
        turn.apply(.toolCall(ToolCallDelta(index: 0, id: "real", name: nil, arguments: "}")))
        #expect(turn.toolCalls == [ModelToolCall(id: "real", name: "page_read", arguments: "{}")])
    }

    @Test("Вызов без аргументов получает {}, без id — свой id")
    func emptyArguments() {
        var turn = ModelTurn()
        turn.apply(.toolCall(ToolCallDelta(index: 0, id: nil, name: "page_tree", arguments: "")))
        #expect(turn.toolCalls.first?.arguments == "{}")
        #expect(turn.toolCalls.first?.id.isEmpty == false)
    }
}
