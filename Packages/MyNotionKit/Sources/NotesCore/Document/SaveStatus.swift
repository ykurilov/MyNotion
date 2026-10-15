import Foundation
import GRDB

/// Состояние сохранения открытой страницы (FR-015): неудачная запись никогда не выдаётся за успешную.
public enum SaveStatus: Sendable, Hashable {
    /// Всё записано на диск.
    case saved
    /// Есть правки, запись запланирована.
    case saving
    /// Запись не удалась; правки в памяти, попытки повторяются.
    case failed(reason: String)

    /// Причина отказа словами для полосы «Изменения не сохранены — <причина>».
    public static func reason(for error: any Error) -> String {
        if let databaseError = error as? DatabaseError {
            switch databaseError.resultCode {
            case .SQLITE_FULL: return "на диске нет места"
            case .SQLITE_READONLY, .SQLITE_PERM, .SQLITE_CANTOPEN, .SQLITE_AUTH: return "нет доступа к файлу записей"
            case .SQLITE_IOERR: return "ошибка чтения или записи диска"
            case .SQLITE_BUSY, .SQLITE_LOCKED: return "файл записей занят"
            case .SQLITE_CORRUPT, .SQLITE_NOTADB: return "файл записей повреждён"
            default: break
            }
        }
        return error.localizedDescription
    }
}
