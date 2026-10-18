import Foundation
import NotesCore

/// Ход импорта: сначала чтение страниц выгрузки, потом запись в базу.
public struct NotionImportProgress: Sendable, Equatable {
    public enum Phase: Sendable, Equatable { case reading, writing }
    public var phase: Phase
    public var done: Int
    public var total: Int
}

/// Страница, где что-то упрощено, и что именно: «таблица ×2», «цитата».
public struct SimplifiedPage: Sendable, Hashable, Codable {
    public var pageTitle: String
    public var items: [String]
}

/// Отчёт после импорта (FR-026): сколько перенесено и что упрощено.
public struct NotionImportReport: Sendable, Equatable {
    public var rootPageId: UUID
    public var rootTitle: String
    public var pageCount: Int
    public var blockCount: Int
    public var simplified: [SimplifiedPage]
}

/// Запись журнала импортов (`import_run`, data-model.md «ImportRun»).
public struct NotionImportRun: Sendable, Equatable {
    public enum Status: String, Sendable { case running, finished, failed }
    public var id: UUID
    public var sourceFingerprint: String
    public var startedAt: Date
    public var finishedAt: Date?
    public var rootPageId: UUID?
    public var importedPages: Int
    public var simplifiedItems: [SimplifiedPage]
    public var status: Status
}

/// Импорт выгрузки Notion в новую ветку «Импорт из Notion — <дата>» (FR-025…FR-027, T089).
public struct NotionImporter: Sendable {
    private let store: NotesStore
    private let now: @Sendable () -> Date
    /// Откатывать ли ветку при ошибке; в тестах выключается, чтобы изобразить падение приложения посреди импорта.
    var rollsBackOnFailure = true
    /// Сколько блоков пишется одной транзакцией: короткие транзакции не держат базу, и правка открытой страницы
    /// не ждёт конца импорта. Страница целиком всегда в одной транзакции.
    var maxBlocksPerTransaction = 2_000

    public init(store: NotesStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.now = now
    }

    /// Удачный импорт той же выгрузки, если он уже был (FR-027): предупредить до начала.
    public func previousImport(withFingerprint fingerprint: String) throws -> NotionImportRun? { nil }

    public func importExport(_ export: PreparedNotionExport,
                             progress: (@Sendable (NotionImportProgress) -> Void)? = nil) throws -> NotionImportReport {
        throw NotionImportError.notAnExport
    }

    /// Импорты, оставшиеся «в работе» после падения приложения: стереть их ветки, пометить неудачными. Сколько откачено.
    @discardableResult
    public func rollBackInterruptedImports() throws -> Int { 0 }

    /// Весь журнал импортов, новые первыми.
    public func runs() throws -> [NotionImportRun] { [] }
}
