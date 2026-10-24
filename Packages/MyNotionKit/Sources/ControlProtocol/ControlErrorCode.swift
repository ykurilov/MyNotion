import Foundation

/// Группа ошибки — она же код выхода команды (contracts/protocol.md, «Коды ошибок и коды выхода»).
public enum ControlErrorGroup: String, Sendable, CaseIterable {
    case usage, notFound, conflict, unavailable, internalFailure

    public var exitCode: Int32 {
        switch self {
        case .usage: 2
        case .notFound: 3
        case .conflict: 4
        case .unavailable: 5
        case .internalFailure: 1
        }
    }
}

/// Закрытый список кодов ошибок. Новый код — только с новой версией протокола.
public enum ControlErrorCode: String, Sendable, Hashable, Codable, CaseIterable {
    // Неверный вызов
    case unknownCommand = "unknown_command"
    case invalidArgument = "invalid_argument"
    case missingArgument = "missing_argument"
    case invalidValue = "invalid_value"
    case invalidMarkdown = "invalid_markdown"
    case invalidFormula = "invalid_formula"
    case notBatchable = "not_batchable"
    case forceRequired = "force_required"
    // Не найдено
    case pageNotFound = "page_not_found"
    case blockNotFound = "block_not_found"
    case databaseNotFound = "database_not_found"
    case propertyNotFound = "property_not_found"
    case optionNotFound = "option_not_found"
    case viewNotFound = "view_not_found"
    case rowNotFound = "row_not_found"
    case versionNotFound = "version_not_found"
    case attachmentNotFound = "attachment_not_found"
    case fileNotFound = "file_not_found"
    case windowNotFound = "window_not_found"
    case tabNotFound = "tab_not_found"
    case templateNotFound = "template_not_found"
    // Конфликт
    case ambiguousPage = "ambiguous_page"
    case pageInTrash = "page_in_trash"
    case cannotMove = "cannot_move"
    case wrongPage = "wrong_page"
    case readOnlyProperty = "read_only_property"
    case windowBusy = "window_busy"
    case batchFailed = "batch_failed"
    case notImplemented = "not_implemented"
    case syncDisabled = "sync_disabled"
    // Приложение недоступно
    case appNotRunning = "app_not_running"
    case appNotReady = "app_not_ready"
    case appDisconnected = "app_disconnected"
    case timeout = "timeout"
    case versionMismatch = "version_mismatch"
    // Внутренняя
    case `internal` = "internal"
    case writeFailed = "write_failed"

    public var group: ControlErrorGroup {
        switch self {
        case .unknownCommand, .invalidArgument, .missingArgument, .invalidValue, .invalidMarkdown, .invalidFormula, .notBatchable,
             .forceRequired:
            .usage
        case .pageNotFound, .blockNotFound, .databaseNotFound, .propertyNotFound, .optionNotFound, .viewNotFound, .rowNotFound,
             .versionNotFound, .attachmentNotFound, .fileNotFound, .windowNotFound, .tabNotFound, .templateNotFound:
            .notFound
        case .ambiguousPage, .pageInTrash, .cannotMove, .wrongPage, .readOnlyProperty, .windowBusy, .batchFailed, .notImplemented,
             .syncDisabled:
            .conflict
        case .appNotRunning, .appNotReady, .appDisconnected, .timeout, .versionMismatch:
            .unavailable
        case .internal, .writeFailed:
            .internalFailure
        }
    }

    public var exitCode: Int32 { group.exitCode }
}

/// Предупреждения не делают команду неуспешной.
public enum ControlWarningCode: String, Sendable, Hashable, Codable, CaseIterable {
    case markdownUnsupported = "markdown_unsupported"
    case optionCreated = "option_created"
    case valueConverted = "value_converted"
    case truncated = "truncated"
    /// Импорт прошёл, но в указанную страницу ветку перенести не удалось.
    case notMoved = "not_moved"
}

/// Ошибка команды: сообщение по-русски одним предложением, подсказка — что сделать, в `details` — что нужно агенту дальше.
public struct ControlError: Error, Sendable, Hashable, Codable {
    public var code: ControlErrorCode
    public var message: String
    public var hint: String?
    public var details: ControlJSON?

    public init(_ code: ControlErrorCode, _ message: String, hint: String? = nil, details: ControlJSON? = nil) {
        self.code = code
        self.message = message
        self.hint = hint
        self.details = details
    }
}

extension ControlError: LocalizedError {
    public var errorDescription: String? { message }
}

public struct ControlWarning: Sendable, Hashable, Codable {
    public var code: ControlWarningCode
    public var message: String
    public var line: Int?

    public init(_ code: ControlWarningCode, _ message: String, line: Int? = nil) {
        self.code = code
        self.message = message
        self.line = line
    }
}
