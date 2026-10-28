import ControlProtocol
import Foundation
import Testing
@testable import AIAgent
@testable import AIModels

/// Живые запросы к DeepSeek и OpenRouter (008, этап 4). Идут, только если задана папка с ключами
/// `MYNOTION_LIVE_KEYS` (файлы `deepseek` и `openrouter`); ключи не печатаются и в журнал не попадают.
@Suite("Живые модели", .serialized, .enabled(if: LiveKeys.folder != nil))
struct LiveModelTests {
    private let keys = LiveKeys()

    private func ask(_ client: any ChatModelClient, _ model: ChatModel, level: ReasoningLevel, _ text: String) async throws -> ModelTurn {
        var turn = ModelTurn()
        let request = ModelRequest(messages: [.system("Отвечай по-русски, одним коротким предложением."), .user(text)], tools: [], level: level)
        for try await event in client.stream(request, model: model) { turn.apply(event) }
        return turn
    }

    @Test("DeepSeek напрямую: ответ и рассуждения на каждом уровне")
    func deepSeekDirect() async throws {
        let client = FallbackModelClient(routes: ModelRouteClient(keys: keys.provider))
        for option in ModelCatalog.deepSeekFlash.options {
            let turn = try await ask(client, ModelCatalog.deepSeekFlash, level: option.level, "Сколько будет 17 + 25?")
            #expect(turn.route?.provider == .deepSeek, "\(option.title)")
            #expect(turn.text.contains("42"), "\(option.title): \(turn.text)")
            print("DeepSeek \(option.level): рассуждений \(turn.reasoning.count) знаков, токены \(turn.usage.map { "\($0.promptTokens)/\($0.completionTokens), из кэша \($0.cachedPromptTokens)" } ?? "—")")
        }
    }

    @Test("OpenRouter: GLM и Qwen на каждом уровне, DeepSeek запасным путём")
    func openRouter() async throws {
        let client = FallbackModelClient(routes: ModelRouteClient(keys: keys.provider))
        for model in [ModelCatalog.glmFlash, ModelCatalog.qwenFlash] {
            for option in model.options {
                let turn = try await ask(client, model, level: option.level, "Сколько будет 17 + 25?")
                #expect(turn.route?.provider == .openRouter)
                #expect(turn.text.contains("42"), "\(model.title) \(option.title): \(turn.text)")
                print("\(model.title) \(option.level): рассуждений \(turn.reasoning.count) знаков")
            }
        }
        let routes = ModelRouteClient(keys: keys.provider)
        for level in [ReasoningLevel.none, .low, .high, .max] {
            var turn = ModelTurn()
            let request = ModelRequest(messages: [.user("Сколько будет 17 + 25? Ответь числом.")], tools: [], level: level)
            for try await event in routes.stream(request, route: ModelCatalog.deepSeekFlash.routes[1]) { turn.apply(event) }
            #expect(turn.text.contains("42"), "DeepSeek через OpenRouter \(level): \(turn.text)")
            print("DeepSeek через OpenRouter \(level): рассуждений \(turn.reasoning.count) знаков")
        }
    }

    @Test("Запасной путь: DeepSeek недоступен по сети — ответ приходит через OpenRouter")
    func fallbackOnNetworkFailure() async throws {
        let broken: ModelRouteClient.Transport = { request in
            if request.url?.host == "api.deepseek.com" { throw URLError(.cannotConnectToHost) }
            return try await ModelRouteClient.urlSession(request)
        }
        let client = FallbackModelClient(routes: ModelRouteClient(keys: keys.provider, transport: broken))
        let turn = try await ask(client, ModelCatalog.deepSeekFlash, level: .none, "Сколько будет 17 + 25?")
        #expect(turn.route?.provider == .openRouter)
        #expect(turn.text.contains("42"))
    }

    @Test("Запасной путь: DeepSeek молчит дольше срока первого кусочка — ответ через OpenRouter")
    func fallbackOnSilence() async throws {
        let silent: ModelRouteClient.Transport = { request in
            if request.url?.host == "api.deepseek.com" { try await Task.sleep(for: .seconds(30)) }
            return try await ModelRouteClient.urlSession(request)
        }
        let client = FallbackModelClient(routes: ModelRouteClient(keys: keys.provider, transport: silent), firstTokenTimeout: .seconds(3))
        let turn = try await ask(client, ModelCatalog.deepSeekFlash, level: .none, "Сколько будет 17 + 25?")
        #expect(turn.route?.provider == .openRouter)
        #expect(turn.text.contains("42"))
    }

    @Test("DeepSeek с рассуждениями: в истории ход с инструментом без рассуждений (был «Без рассуждений» или OpenRouter) — не 400")
    func deepSeekToolHistoryWithoutReasoning() async throws {
        let routes = ModelRouteClient(keys: keys.provider)
        let call = ModelToolCall(id: "call_live_1", name: "page_read", arguments: #"{"page":"current"}"#)
        let messages: [ModelMessage] = [.system(AgentPrompt.systemInstruction), .user("Что за сыр на странице?"),
                                        .assistant(text: "", reasoning: nil, toolCalls: [call]),
                                        .tool(callID: call.id, content: ##"{"markdown":"# Покупки\n- сыр «Маасдам»"}"##)]
        for level in [ReasoningLevel.low, .high] {
            var turn = ModelTurn()
            let request = ModelRequest(messages: messages, tools: NoteToolbox.tools, level: level)
            for try await event in routes.stream(request, route: ModelCatalog.deepSeekFlash.routes[0]) { turn.apply(event) }
            #expect(turn.text.contains("Маасдам"), "\(level): \(turn.text)")
        }
    }

    @Test("Агент вызывает инструмент и отвечает по его результату — каждой моделью")
    func agentTools() async throws {
        let client = FallbackModelClient(routes: ModelRouteClient(keys: keys.provider))
        for model in ModelCatalog.all {
            let toolbox = NoteToolbox { request in
                guard request.command == "page.read" else { return .success(request.id, ["ok": true]) }
                return .success(request.id, ["markdown": "# Список покупок\n- молоко\n- хлеб\n- сыр «Маасдам»"])
            }
            let loop = AgentLoop(model: client, toolbox: toolbox, maxSteps: 6)
            var entries: [ChatEntry] = []
            let question = ChatEntry.user("Прочитай открытую страницу инструментом и назови, какой сыр в списке.", page: nil)
            for try await event in loop.run(entries: [question], model: model, level: model.defaultLevel) {
                if case .entry(let entry) = event { entries.append(entry) }
            }
            let tools = entries.filter { $0.kind == .tool }
            #expect(tools.contains { $0.toolName == "page_read" && $0.ok == true }, "\(model.title): \(entries.map(\.kind))")
            #expect(entries.last?.text.contains("Маасдам") == true, "\(model.title): \(entries.last?.text ?? "")")
            print("\(model.title): инструменты \(tools.map { $0.toolName ?? "" }), ответ \(entries.last?.text.count ?? 0) знаков")
        }
    }

    @Test("Второй ход того же чата берёт начало запроса из кэша DeepSeek")
    func promptCache() async throws {
        let client = FallbackModelClient(routes: ModelRouteClient(keys: keys.provider))
        let page = PageContext(pageID: "p", title: "Заметки", path: "Заметки", markdown: String(repeating: "Строка заметки о проекте. ", count: 300),
                               truncated: false)
        var history = [ChatEntry.user("Сколько примерно слов на странице? Ответь числом.", page: page)]
        var cached = 0
        for step in 0..<2 {
            var turn = ModelTurn()
            let request = ModelRequest(messages: AgentPrompt.messages(for: history), tools: NoteToolbox.tools, level: .none)
            for try await event in client.stream(request, model: ModelCatalog.deepSeekFlash) { turn.apply(event) }
            history.append(.assistant(turn: turn, modelID: ModelCatalog.deepSeekFlash.id))
            history.append(.user("А строк?", page: PageContext(pageID: "p", title: "Заметки", path: "Заметки", markdown: "", truncated: false,
                                                                 unchanged: true)))
            cached = turn.usage?.cachedPromptTokens ?? 0
            print("Кэш, ход \(step + 1): \(turn.usage.map { "\($0.cachedPromptTokens) из \($0.promptTokens)" } ?? "—")")
        }
        #expect(cached > 1_000)
    }

    @Test("Проверка ключей из настроек: настоящие подходят, выдуманный — «не подходит»")
    func keyCheck() async throws {
        try await ModelKeyCheck.check(try #require(keys.read("deepseek")), provider: .deepSeek)
        try await ModelKeyCheck.check(try #require(keys.read("openrouter")), provider: .openRouter)
        await #expect(throws: ModelError.invalidKey(.openRouter)) {
            try await ModelKeyCheck.check("sk-or-v1-0000000000000000000000000000000000000000000000000000000000000000", provider: .openRouter)
        }
    }
}

struct LiveKeys: Sendable {
    static var folder: URL? {
        ProcessInfo.processInfo.environment["MYNOTION_LIVE_KEYS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    func read(_ name: String) -> String? {
        guard let folder = Self.folder, let data = try? Data(contentsOf: folder.appendingPathComponent(name)) else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var provider: ModelRouteClient.Keys {
        { provider in
            switch provider {
            case .deepSeek: LiveKeys().read("deepseek")
            case .openRouter: LiveKeys().read("openrouter")
            }
        }
    }
}
