import Foundation

/// Выгрузка, готовая к импорту: папка с деревом страниц и отпечаток содержимого.
public struct PreparedNotionExport: Sendable {
    /// Папка, где лежат страницы выгрузки.
    public let contentRoot: URL
    /// SHA-256 путей и содержимого всех файлов: одна и та же выгрузка — ZIP или распакованная — даёт один отпечаток.
    public let fingerprint: String
    /// Временная папка распаковки; `nil`, если на вход дали уже распакованную папку.
    let temporaryFolder: URL?

    /// Убрать временную папку распаковки.
    public func discard() {
        if let temporaryFolder { try? FileManager.default.removeItem(at: temporaryFolder) }
    }
}

public enum NotionImportError: Error, LocalizedError, Equatable {
    case sourceMissing(String)
    case cannotUnpack(String)
    case notAnExport
    case cannotRead(String)
    case cannotWrite(String)

    public var errorDescription: String? {
        switch self {
        case .sourceMissing(let path): "Файл «\(path)» не найден."
        case .cannotUnpack(let reason): "Не удалось распаковать выгрузку: \(reason)."
        case .notAnExport: "В выбранном файле нет страниц Notion. Нужна выгрузка «Export → Markdown & CSV»."
        case .cannotRead(let reason): "Не удалось прочитать выгрузку: \(reason)."
        case .cannotWrite(let reason): "Импорт не записан: \(reason). Прежние записи не тронуты."
        }
    }
}

/// Распаковка ZIP из Notion системной `ditto` во временную папку, включая вложенные ZIP большой выгрузки (T087).
public struct NotionExportUnpacker: Sendable {
    public init() {}

    public func prepare(_ source: URL) throws -> PreparedNotionExport {
        throw NotionImportError.notAnExport
    }
}
