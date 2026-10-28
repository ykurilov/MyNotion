import Foundation

/// Один путь к модели: запрос с потоком ответа, разбор строк, ошибки по кодам ответа.
public struct ModelRouteClient: Sendable {
    /// Ответ сервера и строки тела; в тестах — подменная сеть.
    public typealias Transport = @Sendable (URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, Error>)
    /// Ключ поставщика в момент запроса: Юрий мог поменять его в Настройках.
    public typealias Keys = @Sendable (ModelProvider) async -> String?

    private let keys: Keys
    private let transport: Transport

    public init(keys: @escaping Keys, transport: Transport? = nil) {
        self.keys = keys
        self.transport = transport ?? Self.urlSession
    }

    public static func urlRequest(for request: ModelRequest, route: ModelRoute, key: String) -> URLRequest {
        var urlRequest = URLRequest(url: route.provider.endpoint, timeoutInterval: idleTimeout)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if route.provider == .openRouter {
            urlRequest.setValue("MyNotion", forHTTPHeaderField: "X-Title")
            urlRequest.setValue("https://kurilov.cloud/mynotion", forHTTPHeaderField: "HTTP-Referer")
        }
        urlRequest.httpBody = ChatCompletionBody.data(for: request, route: route)
        return urlRequest
    }

    /// Первое событие — `.route`, когда сервер ответил 200.
    public func stream(_ request: ModelRequest, route: ModelRoute) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(request, route: route, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.modelError(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(_ request: ModelRequest, route: ModelRoute,
                     continuation: AsyncThrowingStream<ModelStreamEvent, Error>.Continuation) async throws {
        guard let key = await keys(route.provider)?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw ModelError.missingKey(route.provider)
        }
        let (response, lines) = try await transport(Self.urlRequest(for: request, route: route, key: key))
        guard (200..<300).contains(response.statusCode) else {
            var body = ""
            for try await line in lines where body.utf8.count < 16_000 { body += line + "\n" }
            throw ModelError.status(response.statusCode, body: body, provider: route.provider)
        }
        continuation.yield(.route(route))
        var isFinished = false
        for try await line in lines {
            try Task.checkCancellation()
            switch try StreamChunkDecoder.decode(line: line, provider: route.provider) {
            case .done: return
            case .events(let events):
                for event in events {
                    if case .finished = event { isFinished = true }
                    continuation.yield(event)
                }
            }
        }
        try Task.checkCancellation()
        // Связь оборвалась «чисто»: без [DONE] и причины конца недописанный ответ сошёл бы за готовый.
        guard isFinished else { throw ModelError.network }
    }

    static func modelError(_ error: Error) -> Error {
        switch error {
        case let error as ModelError: error
        case let error as URLError: error.code == .cancelled ? CancellationError() : ModelError.network(error)
        case is CancellationError: error
        default: ModelError.badResponse
        }
    }

    /// Сколько ждать следующего кусочка ответа. Первый кусочек сторожит `FallbackModelClient`.
    static let idleTimeout: TimeInterval = 90

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = idleTimeout
        configuration.timeoutIntervalForResource = 15 * 60
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    static let urlSession: Transport = { request in
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw ModelError.badResponse }
        let lines = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines { continuation.yield(line) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (http, lines)
    }
}
