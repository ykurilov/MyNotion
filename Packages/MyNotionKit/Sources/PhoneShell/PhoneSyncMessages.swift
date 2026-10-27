import Foundation
import Sync

/// Слова синхронизации на iPhone: ошибки подключения простыми словами и сообщения цикла про «этот iPhone».
public enum PhoneSyncMessages {
    public static let emptyCode = "Вставьте код с Mac: на Mac откройте «Настройки → Синхронизация» и нажмите «Добавить Mac или iPhone»"
    public static let mistypedCode = "В коде опечатка — сверьте его с экраном Mac или скопируйте заново"
    public static let expiredCode = "Код устарел или им уже подключили другое устройство — на Mac нажмите «Добавить Mac или iPhone» ещё раз"
    public static let noNetwork = "Нет связи с сервером — проверьте интернет и попробуйте ещё раз"
    public static let unauthorized = "Сервер не принял этот iPhone — выключите синхронизацию на нём и подключите заново кодом с Mac"
    public static let missingSecrets = "iPhone забыл код подключения — выключите синхронизацию на нём и подключите заново кодом с Mac"

    /// Ошибка подключения, списка устройств или выключения.
    public static func message(for error: any Error) -> String {
        switch error {
        case JoinCodeError.mistyped: mistypedCode
        case SyncServerError.inviteExpired: expiredCode
        case SyncServerError.unauthorized: unauthorized
        case SyncSetupError.missingSecrets: missingSecrets
        case is URLError: noNetwork
        default: onPhone(SyncEngine.message(for: error))
        }
    }

    /// Сообщения общего цикла написаны для Mac; на iPhone «этот Mac» — это «этот iPhone».
    public static func onPhone(_ message: String) -> String {
        message.replacingOccurrences(of: "этом Mac", with: "этом iPhone")
            .replacingOccurrences(of: "Этот Mac", with: "Этот iPhone")
    }
}
