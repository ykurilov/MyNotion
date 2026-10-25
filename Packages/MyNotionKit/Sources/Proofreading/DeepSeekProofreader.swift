import Foundation

/// Исправитель через DeepSeek. Ключ берётся в момент проверки, а не при запуске приложения.
public struct DeepSeekProofreader: TextProofreader {
    /// Отправка запроса; в тестах — подменный ответ.
    public typealias Send = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let apiKey: @Sendable () async throws -> String?
    private let send: Send

    public init(apiKey: @escaping @Sendable () async throws -> String?, send: Send? = nil) {
        self.apiKey = apiKey
        self.send = send ?? Self.urlSession
    }

    public func proofread(_ text: String) async throws -> String {
        guard text.utf16.count <= DeepSeekRequest.maximumLength else { throw ProofreadingError.tooLong }
        guard let key = try await apiKey()?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw ProofreadingError.missingKey
        }
        let data = try await perform(DeepSeekRequest.urlRequest(text: text, key: key))
        return try DeepSeekRequest.correctedText(from: data)
    }

    /// «Проверить» в Настройках: ключ подходит, если DeepSeek отдаёт по нему список моделей.
    public func checkKey(_ key: String) async throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw ProofreadingError.missingKey }
        _ = try await perform(DeepSeekRequest.keyCheckRequest(key: key))
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await send(request)
        } catch let error as URLError {
            throw DeepSeekRequest.error(for: error)
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw ProofreadingError.badResponse }
        if let error = DeepSeekRequest.error(forStatus: http.statusCode) { throw error }
        return data
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = DeepSeekRequest.timeout
        configuration.timeoutIntervalForResource = DeepSeekRequest.timeout
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    private static let urlSession: Send = { request in try await session.data(for: request) }
}
