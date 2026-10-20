import Foundation
import GRDB
import Synchronization

/// Хранилище страниц и блоков. Читает дерево без текста блоков и страницу целиком;
/// пишет только транзакциями, ставя каждому изменённому полю метку гибридных часов.
public final class NotesStore: Sendable {
    public let database: AppDatabase
    public let clock: HybridLogicalClock
    private let writeHooks = Mutex<[any NotesWriteHook]>([])
    private let deletionMarks = Mutex(false)

    public init(database: AppDatabase, clock: HybridLogicalClock) {
        self.database = database
        self.clock = clock
    }

    /// Подписчик (поиск, синхронизация) будет писать в каждую транзакцию записи перед её фиксацией.
    public func addWriteHook(_ hook: any NotesWriteHook) {
        writeHooks.withLock { $0.append(hook) }
    }

    /// Удалённый блок остаётся пометкой с меткой часов, пока её не получат все устройства (data-model.md, «Block»).
    /// Включает синхронизация; без неё удалённое стирается сразу.
    package var keepsDeletionMarks: Bool {
        get { deletionMarks.withLock { $0 } }
        set { deletionMarks.withLock { $0 = newValue } }
    }

    // MARK: Чтение

    /// Все страницы без блоков, по порядку ключей.
    public func pageOutline() throws -> [Page] {
        try database.dbWriter.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM page ORDER BY sortKey, id").map(Page.init(row:))
        }
    }

    /// Страница и её блоки по порядку; `nil`, если страницы нет.
    public func pageContent(_ pageId: UUID) throws -> PageContent? {
        try database.dbWriter.read { db in
            guard let page = try NotesTransaction.fetchPage(pageId, in: db) else { return nil }
            return PageContent(page: page, blocks: try NotesTransaction.fetchBlocks(ofPage: pageId, in: db),
                               removedContainers: try NotesTransaction.fetchRemovedContainers(ofPage: pageId, in: db))
        }
    }

    /// Неразрешённые конфликты текста в блоках страницы.
    public func unresolvedConflicts(ofPage pageId: UUID) throws -> [Conflict] {
        try database.dbWriter.read { db in
            try Row.fetchAll(db, sql: """
                SELECT conflict.* FROM conflict JOIN block ON block.id = conflict.blockId
                WHERE block.pageId = ? AND conflict.resolvedAt IS NULL
                ORDER BY conflict.detectedAt, conflict.id
                """, arguments: [pageId.databaseText]).map(Conflict.init(row:))
        }
    }

    // MARK: Вид окна (локально, без меток часов и подписчиков)

    public func windowState(_ windowId: UUID) throws -> WindowState? {
        try database.dbWriter.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM window_state WHERE windowId = ?", arguments: [windowId.databaseText])
                .map(WindowState.init(row:))
        }
    }

    public func saveWindowState(_ state: WindowState) throws {
        try database.dbWriter.write { db in try state.save(in: db) }
    }

    // MARK: Запись

    /// Одна транзакция: всё внутри `body` и записи подписчиков фиксируются вместе или не фиксируются вовсе.
    @discardableResult
    public func write<T>(_ body: (NotesTransaction) throws -> T) throws -> T {
        let hooks = writeHooks.withLock { $0 }
        return try database.dbWriter.write { db in
            let transaction = NotesTransaction(db: db, clock: clock, keepsDeletionMarks: keepsDeletionMarks)
            let result = try body(transaction)
            try transaction.giveEveryTouchedPageABlock()
            let changes = transaction.changes
            if !changes.isEmpty {
                for hook in hooks {
                    try hook.notesWillCommit(changes, in: transaction)
                }
            }
            return result
        }
    }
}

/// Подписчик на запись: вызывается внутри транзакции, до фиксации. Ошибка подписчика отменяет всю запись.
/// Ядро о подписчиках ничего не знает (конституция, принцип V).
public protocol NotesWriteHook: Sendable {
    func notesWillCommit(_ changes: NotesChanges, in transaction: NotesTransaction) throws
}

/// Что изменила транзакция.
public struct NotesChanges: Sendable {
    public internal(set) var pages: [PageChange] = []
    public internal(set) var blocks: [BlockChange] = []
    /// Страницы, стёртые навсегда; их блоки стёрты вместе с ними.
    public internal(set) var erasedPageIds: [UUID] = []
    /// Версия текста, поверх которой записан новый текст блока: по ней другой Mac узнаёт одновременную правку (R8).
    public internal(set) var textBaseClocks: [UUID: HybridTimestamp] = [:]
    /// Конфликты, по которым Юрий сделал выбор.
    public internal(set) var resolvedConflicts: [Conflict] = []
    /// Отметки «сделано» напоминаний — свои и пришедшие с других Mac.
    public internal(set) var reminderStates: [ReminderState] = []

    public var isEmpty: Bool {
        pages.isEmpty && blocks.isEmpty && erasedPageIds.isEmpty && resolvedConflicts.isEmpty && reminderStates.isEmpty
    }
}

public struct PageChange: Sendable {
    public let page: Page
    public let changedFields: Set<Page.Field>
    public let isNew: Bool
}

public enum BlockChange: Sendable {
    case saved(Block, changedFields: Set<Block.Field>, isNew: Bool)
    case erased(blockId: UUID, pageId: UUID)
}

public enum NotesStoreError: Error, Equatable, LocalizedError {
    case pageNotFound(UUID)
    case blockNotFound(UUID)
    case invalidPage(String)
    case invalidBlock(String)
    case corruptedRecord(String)

    public var errorDescription: String? {
        switch self {
        case .pageNotFound(let id): "Страница \(id) не найдена"
        case .blockNotFound(let id): "Блок \(id) не найден"
        case .invalidPage(let reason): "Страница не записана: \(reason)"
        case .invalidBlock(let reason): "Блок не записан: \(reason)"
        case .corruptedRecord(let reason): "Запись в базе повреждена: \(reason)"
        }
    }
}

/// Значение для SQL подписчика.
public enum SQLValue: Sendable, Hashable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    var databaseValue: DatabaseValue {
        switch self {
        case .null: .null
        case .integer(let value): value.databaseValue
        case .real(let value): value.databaseValue
        case .text(let value): value.databaseValue
        case .blob(let value): value.databaseValue
        }
    }
}
