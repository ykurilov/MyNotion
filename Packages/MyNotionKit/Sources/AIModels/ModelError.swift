import ControlProtocol
import Foundation

/// Сбой запроса к модели. `message` — простая фраза для панели чата; ключа в ней не бывает.
public enum ModelError: Error, Sendable, Hashable {
    case missingKey(ModelProvider)
    case invalidKey(ModelProvider)
    case noBalance(ModelProvider)
    case rateLimited(ModelProvider)
    case server(ModelProvider, Int)
    case network
    case timeout
    /// Поставщик отказал и объяснил почему (слишком длинный чат, неверный вызов).
    case provider(String)
    case badResponse

    public var message: String {
        switch self {
        case .missingKey(let provider): "Нет ключа \(provider.title). Добавьте его в Настройках, в разделе «Синхронизация»."
        case .invalidKey(let provider): "Ключ \(provider.title) не подходит. Проверьте его в Настройках."
        case .noBalance(let provider): "На счёте \(provider.title) закончились деньги."
        case .rateLimited(let provider): "\(provider.title) просит подождать: слишком много запросов. Попробуйте через минуту."
        case .server(let provider, _): "\(provider.title) сейчас не отвечает. Попробуйте чуть позже."
        case .network: "Нет связи с интернетом."
        case .timeout: "Модель слишком долго не отвечает. Попробуйте ещё раз."
        case .provider(let text): "Модель вернула ошибку: \(text)"
        case .badResponse: "Модель прислала непонятный ответ. Попробуйте ещё раз."
        }
    }

    /// Можно повторить запрос другим путём: сбой связи или сервера, а не ошибка в самом запросе или ключе.
    public var allowsFallback: Bool {
        switch self {
        case .missingKey, .rateLimited, .server, .network, .timeout: true
        case .invalidKey, .noBalance, .provider, .badResponse: false
        }
    }

    static func status(_ status: Int, body: String, provider: ModelProvider) -> ModelError {
        switch status {
        case 401, 403: return .invalidKey(provider)
        case 402: return .noBalance(provider)
        case 408: return .timeout
        case 429: return .rateLimited(provider)
        case 500...: return .server(provider, status)
        default:
            let text = (try? ControlJSON(parsing: body))?["error"]?["message"]?.string
            return .provider(text.map { String($0.prefix(300)) } ?? "код \(status)")
        }
    }

    /// Ошибка внутри потока: `{"error":{"code":502,"message":"…"}}`.
    static func streamError(_ error: ControlJSON, provider: ModelProvider) -> ModelError {
        let code = error["code"]?.int ?? Int(error["code"]?.string ?? "") ?? 0
        if code == 429 || code >= 500 { return status(code, body: "", provider: provider) }
        return .provider(String((error["message"]?.string ?? "без описания").prefix(300)))
    }

    static func network(_ error: URLError) -> ModelError {
        error.code == .timedOut ? .timeout : .network
    }
}
