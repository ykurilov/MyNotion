import Foundation

/// Проверка ключа из настроек: короткий запрос без модели. Неверный ключ, пустой счёт, нет связи — `ModelError`.
public enum ModelKeyCheck {
    public static func check(_ key: String, provider: ModelProvider, session: URLSession = .shared) async throws {
        var request = URLRequest(url: provider.keyCheckURL, timeoutInterval: 15)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw ModelError.network(error)
        }
        guard let http = response as? HTTPURLResponse else { throw ModelError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw ModelError.status(http.statusCode, body: String(decoding: data, as: UTF8.self), provider: provider)
        }
    }
}

extension ModelProvider {
    /// Сведения о ключе: OpenRouter — `/key`, DeepSeek — баланс.
    var keyCheckURL: URL {
        switch self {
        case .deepSeek: URL(string: "https://api.deepseek.com/user/balance")!
        case .openRouter: URL(string: "https://openrouter.ai/api/v1/key")!
        }
    }
}
