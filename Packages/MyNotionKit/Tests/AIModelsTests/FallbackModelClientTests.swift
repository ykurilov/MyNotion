import Foundation
import Synchronization
import Testing
@testable import AIModels

/// Подменная сеть: ответы по очереди для каждого поставщика, запросы запоминаются.
final class FakeModelNetwork: Sendable {
    enum Reply: Sendable {
        case lines([String])
        case status(Int, String)
        case failure(URLError.Code)
        /// Ответ не приходит, пока запрос не отменят.
        case silence
        /// Часть потока, затем обрыв связи.
        case linesThenFailure([String], URLError.Code)
        /// Строки после паузы.
        case delayed(Duration, [String])
    }

    private let replies: Mutex<[ModelProvider: [Reply]]>
    private let requests = Mutex<[URLRequest]>([])

    init(_ replies: [ModelProvider: [Reply]]) {
        self.replies = Mutex(replies)
    }

    var providers: [ModelProvider] {
        requests.withLock { $0.compactMap { request in
            request.url?.host == "api.deepseek.com" ? .deepSeek : request.url?.host == "openrouter.ai" ? .openRouter : nil
        } }
    }

    var lastRequest: URLRequest? { requests.withLock { $0.last } }

    var transport: ModelRouteClient.Transport {
        { [self] request in
            requests.withLock { $0.append(request) }
            let provider: ModelProvider = request.url?.host == "api.deepseek.com" ? .deepSeek : .openRouter
            let reply = replies.withLock { all -> Reply in
                guard var queue = all[provider], !queue.isEmpty else { return .failure(.cannotConnectToHost) }
                let next = queue.removeFirst()
                all[provider] = queue
                return next
            }
            let ok = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            switch reply {
            case .lines(let lines):
                return (ok, AsyncThrowingStream { continuation in
                    for line in lines { continuation.yield(line) }
                    continuation.finish()
                })
            case .status(let code, let body):
                let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
                return (response, AsyncThrowingStream { continuation in
                    continuation.yield(body)
                    continuation.finish()
                })
            case .failure(let code):
                throw URLError(code)
            case .silence:
                try await Task.sleep(for: .seconds(60))
                throw URLError(.timedOut)
            case .delayed(let pause, let lines):
                return (ok, AsyncThrowingStream { continuation in
                    let task = Task {
                        try? await Task.sleep(for: pause)
                        for line in lines { continuation.yield(line) }
                        continuation.finish()
                    }
                    continuation.onTermination = { _ in task.cancel() }
                })
            case .linesThenFailure(let lines, let code):
                return (ok, AsyncThrowingStream { continuation in
                    for line in lines { continuation.yield(line) }
                    continuation.finish(throwing: URLError(code))
                })
            }
        }
    }
}

private func answer(_ text: String) -> [String] {
    [#"data: {"choices":[{"delta":{"content":"\#(text)"}}]}"#, #"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"#, "data: [DONE]"]
}

private let bothKeys: ModelRouteClient.Keys = { _ in "test-key" }

private func collect(_ client: FallbackModelClient, model: ChatModel = ModelCatalog.deepSeekFlash) async throws -> ModelTurn {
    var turn = ModelTurn()
    for try await event in client.stream(ModelRequest(messages: [.user("Привет")], tools: [], level: .none), model: model) {
        turn.apply(event)
    }
    return turn
}

private func client(_ network: FakeModelNetwork, keys: @escaping ModelRouteClient.Keys = bothKeys,
                    timeout: Duration = .seconds(5), now: @escaping @Sendable () -> Date = Date.init) -> FallbackModelClient {
    FallbackModelClient(routes: ModelRouteClient(keys: keys, transport: network.transport), firstTokenTimeout: timeout, now: now)
}

@Suite("Запасной путь DeepSeek → OpenRouter")
struct FallbackModelClientTests {
    @Test("DeepSeek отвечает — OpenRouter не нужен")
    func direct() async throws {
        let network = FakeModelNetwork([.deepSeek: [.lines(answer("Привет"))]])
        let turn = try await collect(client(network))
        #expect(turn.text == "Привет")
        #expect(turn.route?.provider == .deepSeek)
        #expect(network.providers == [.deepSeek])
    }

    @Test("Нет связи, 5xx, 429 у DeepSeek — тот же запрос через OpenRouter",
          arguments: [FakeModelNetwork.Reply.failure(.notConnectedToInternet), .status(503, "busy"), .status(429, "slow"),
                      .status(500, #"{"error":{"message":"oops"}}"#)])
    func fallback(reply: FakeModelNetwork.Reply) async throws {
        let network = FakeModelNetwork([.deepSeek: [reply], .openRouter: [.lines(answer("Через запасной"))]])
        let turn = try await collect(client(network))
        #expect(turn.text == "Через запасной")
        #expect(turn.route == ModelCatalog.deepSeekFlash.routes[1])
        #expect(network.providers == [.deepSeek, .openRouter])
        let body = try #require(network.lastRequest?.httpBody)
        #expect(String(decoding: body, as: UTF8.self).contains("deepseek/deepseek-v4.1-flash-1017:nitro"))
    }

    @Test("DeepSeek молчит дольше срока до первого кусочка — OpenRouter")
    func firstTokenTimeout() async throws {
        let network = FakeModelNetwork([.deepSeek: [.silence], .openRouter: [.lines(answer("Успел"))]])
        let turn = try await collect(client(network, timeout: .milliseconds(100)))
        #expect(turn.text == "Успел")
        #expect(network.providers == [.deepSeek, .openRouter])
    }

    @Test("Нет ключа DeepSeek — сразу OpenRouter")
    func missingDeepSeekKey() async throws {
        let network = FakeModelNetwork([.openRouter: [.lines(answer("Без DeepSeek"))]])
        let turn = try await collect(client(network, keys: { $0 == .openRouter ? "or-key" : nil }))
        #expect(turn.text == "Без DeepSeek")
        #expect(network.providers == [.openRouter])
    }

    @Test("Неверный ключ DeepSeek — ошибка, запасной путь не нужен")
    func invalidKeyStops() async throws {
        let network = FakeModelNetwork([.deepSeek: [.status(401, "")], .openRouter: [.lines(answer("лишнее"))]])
        await #expect(throws: ModelError.invalidKey(.deepSeek)) { try await collect(client(network)) }
        #expect(network.providers == [.deepSeek])
    }

    @Test("Обрыв после первого кусочка — ошибка без повтора: ответ задвоился бы")
    func failureAfterStart() async throws {
        let network = FakeModelNetwork([.deepSeek: [.linesThenFailure([#"data: {"choices":[{"delta":{"content":"Нач"}}]}"#], .networkConnectionLost)],
                                        .openRouter: [.lines(answer("лишнее"))]])
        await #expect(throws: ModelError.network) { try await collect(client(network)) }
        #expect(network.providers == [.deepSeek])
    }

    @Test("Первый кусочек приходит ровно к сроку сторожа — ответ одним путём, без задвоения")
    func watchdogRace() async throws {
        for round in 0..<300 {
            let pause = Duration.microseconds(1_500 + (round % 30) * 50)
            let network = FakeModelNetwork([.deepSeek: [.delayed(pause, answer("Напрямую"))], .openRouter: [.lines(answer("Запасной"))]])
            let turn = try await collect(client(network, timeout: .milliseconds(2)))
            #expect(turn.text == "Напрямую" || turn.text == "Запасной", "Раунд \(round): \(turn.text)")
            if turn.text == "Запасной" { #expect(turn.route?.provider == .openRouter) }
            if turn.text == "Напрямую" { #expect(network.providers == [.deepSeek], "Раунд \(round)") }
        }
    }

    @Test("Поток оборвался без [DONE] и без причины конца — ошибка связи, а не готовый ответ")
    func cutStream() async throws {
        let network = FakeModelNetwork([.deepSeek: [.lines([#"data: {"choices":[{"delta":{"content":"Нач"}}]}"#])],
                                        .openRouter: [.lines(answer("лишнее"))]])
        await #expect(throws: ModelError.network) { try await collect(client(network)) }
        #expect(network.providers == [.deepSeek], "Ответ уже начался — запасной путь задвоил бы его")
    }

    @Test("Поток кончился причиной конца без [DONE] — ответ готов")
    func finishedWithoutDone() async throws {
        let network = FakeModelNetwork([.deepSeek: [.lines(Array(answer("Готово").dropLast()))]])
        #expect(try await collect(client(network)).text == "Готово")
    }

    @Test("Ответ 200 с ошибкой JSON-телом без data: — ошибка поставщика, не пустой ответ")
    func bareErrorBody() async throws {
        let network = FakeModelNetwork([.openRouter: [.lines([#"{"error":{"code":400,"message":"No endpoints found"}}"#])]])
        await #expect(throws: ModelError.provider("No endpoints found")) { try await collect(client(network), model: ModelCatalog.glmFlash) }
    }

    @Test("После сбоя две минуты запросы идут сразу через OpenRouter, потом снова напрямую")
    func stickyFallback() async throws {
        let clock = Mutex(Date(timeIntervalSince1970: 1_000))
        let network = FakeModelNetwork([.deepSeek: [.status(503, ""), .lines(answer("снова напрямую"))],
                                        .openRouter: [.lines(answer("1")), .lines(answer("2"))]])
        let model = client(network, now: { clock.withLock { $0 } })
        _ = try await collect(model)
        clock.withLock { $0 += 60 }
        #expect(try await collect(model).text == "2")
        #expect(network.providers == [.deepSeek, .openRouter, .openRouter])
        clock.withLock { $0 += 61 }
        #expect(try await collect(model).text == "снова напрямую")
        #expect(network.providers.last == .deepSeek)
    }

    @Test("Сбой обоих путей — ошибка последнего")
    func bothFail() async throws {
        let network = FakeModelNetwork([.deepSeek: [.failure(.timedOut)], .openRouter: [.status(402, "")]])
        await #expect(throws: ModelError.noBalance(.openRouter)) { try await collect(client(network)) }
    }

    @Test("GLM: у OpenRouter нет запаса — его ошибка сразу; нет ключа OpenRouter — понятная ошибка")
    func openRouterOnly() async throws {
        let failing = FakeModelNetwork([.openRouter: [.status(503, "")]])
        await #expect(throws: ModelError.server(.openRouter, 503)) { try await collect(client(failing), model: ModelCatalog.glmFlash) }
        let noKey = FakeModelNetwork([:])
        await #expect(throws: ModelError.missingKey(.openRouter)) {
            try await collect(client(noKey, keys: { _ in nil }), model: ModelCatalog.qwenFlash)
        }
        #expect(noKey.providers.isEmpty)
    }

    @Test("Ошибка 400 с текстом поставщика — текст в сообщении, ключа в нём нет")
    func providerMessage() async throws {
        let network = FakeModelNetwork([.openRouter: [.status(400, #"{"error":{"message":"Bad tool schema"}}"#)]])
        do {
            _ = try await collect(client(network, keys: { _ in "secret-123" }), model: ModelCatalog.glmFlash)
            Issue.record("Ошибки не было")
        } catch let error as ModelError {
            #expect(error == .provider("Bad tool schema"))
            #expect(error.message.contains("Bad tool schema"))
            #expect(!error.message.contains("secret-123"))
        }
    }
}

@Suite("Ошибки моделей по-русски")
struct ModelErrorTests {
    @Test("Каждая ошибка — простая фраза; запасной путь только для сбоев связи и сервера")
    func messages() {
        let all: [ModelError] = [.missingKey(.openRouter), .invalidKey(.deepSeek), .noBalance(.deepSeek), .rateLimited(.openRouter),
                                 .server(.deepSeek, 502), .network, .timeout, .provider("x"), .badResponse]
        for error in all { #expect(!error.message.isEmpty) }
        #expect(ModelError.missingKey(.openRouter).message.contains("OpenRouter"))
        #expect(ModelError.invalidKey(.deepSeek).message.contains("DeepSeek"))
        #expect(all.filter(\.allowsFallback) == [.missingKey(.openRouter), .rateLimited(.openRouter), .server(.deepSeek, 502), .network, .timeout])
    }
}
