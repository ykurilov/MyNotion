import Foundation

/// Исправитель текста: присылает исправленный текст целиком. В приложении — DeepSeek, в тестах — подмена.
public protocol TextProofreader: Sendable {
    func proofread(_ text: String) async throws -> String
}

/// Что пошло не так — словами для Юрия, без слов разработчика.
public enum ProofreadingError: Error, Equatable, LocalizedError {
    case missingKey
    case invalidKey
    case noConnection
    case timeout
    case insufficientBalance
    case rateLimited
    case server(status: Int)
    case badResponse
    case tooLong
    /// Метки упоминаний, кода или переводы строк не вернулись — текст не тронут.
    case formattingLost
    /// Пока шла проверка, выделенный текст поменяли.
    case textChanged
    /// Исправитель не подключён (служебные окна без приложения).
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .missingKey: "Нет ключа DeepSeek — добавьте его в Настройках"
        case .invalidKey: "DeepSeek не принял ключ — проверьте его в Настройках"
        case .noConnection: "Нет связи с DeepSeek — проверьте интернет"
        case .timeout: "DeepSeek не ответил за 30 секунд — попробуйте ещё раз"
        case .insufficientBalance: "На счёте DeepSeek закончились деньги"
        case .rateLimited: "DeepSeek просит подождать: слишком много запросов"
        case .server(let status): "DeepSeek не смог ответить (ошибка \(status)) — попробуйте позже"
        case .badResponse: "DeepSeek прислал непонятный ответ — попробуйте ещё раз"
        case .tooLong: "Слишком длинный текст — выделите часть поменьше"
        case .formattingLost: "Не получилось сохранить оформление — текст не изменён"
        case .textChanged: "Текст изменился, пока шла проверка — проверьте ещё раз"
        case .unavailable: "Исправление ошибок здесь недоступно"
        }
    }
}
