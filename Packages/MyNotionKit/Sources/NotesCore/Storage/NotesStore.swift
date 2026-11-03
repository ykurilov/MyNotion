import Foundation
import GRDB
import Synchronization

/// Хранилище страниц и блоков. Читает дерево без текста блоков и страницу целиком;
/// пишет только транзакциями, ставя каждому изменённому полю метку гибридных часов.
public final class NotesStore: Sendable {
    public let database: AppDatabase
    public let clock: HybridLogicalClock
    private let writeHooks = Mutex<[any NotesWriteHook]>([])
    private let treeAddons = Mutex<[any PageTreeAddon]>([])
    private let deletionMarks = Mutex(false)
    private let recordedClock = Mutex<HybridTimestamp?>(nil)

    public init(database: AppDatabase, clock: HybridLogicalClock) {
        self.database = database
        self.clock = clock
        // Часы после запуска начинают с нуля: свои новые метки — позже всех сохранённых, даже если время Mac отстало.
        if let stored = try? database.dbWriter.read(Self.latestStoredStamp) {
            clock.receive(stored)
        }
    }

    /// Подписчик (поиск, синхронизация) будет писать в каждую транзакцию записи перед её фиксацией.
    public func addWriteHook(_ hook: any NotesWriteHook) {
        writeHooks.withLock { $0.append(hook) }
    }

    /// Добавка модуля к копии ветки и переносу страниц (`PageTreeAddon`) — до первой записи.
    public func addTreeAddon(_ addon: any PageTreeAddon) {
        treeAddons.withLock { $0.append(addon) }
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

    /// Одна страница без блоков; `nil`, если её нет.
    public func page(_ pageId: UUID) throws -> Page? {
        try database.dbWriter.read { db in try NotesTransaction.fetchPage(pageId, in: db) }
    }

    /// Один живой блок; `nil`, если его нет или он удалён.
    public func block(_ blockId: UUID) throws -> Block? {
        try database.dbWriter.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM block WHERE id = ? AND isDeleted = 0", arguments: [blockId.databaseText])
                .map(Block.init(row:))
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

    // MARK: Локальные отметки (app_meta, без меток часов и подписчиков)

    /// Отметка этого Mac по ключу, например «индекс обратных ссылок построен».
    public func appMeta(_ key: String) throws -> String? {
        try database.dbWriter.read { db in try String.fetchOne(db, sql: "SELECT value FROM app_meta WHERE key = ?", arguments: [key]) }
    }

    /// Поставить отметку; `nil` — убрать.
    public func setAppMeta(_ key: String, _ value: String?) throws {
        try database.dbWriter.write { db in
            if let value {
                try db.execute(sql: "INSERT INTO app_meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                               arguments: [key, value])
            } else {
                try db.execute(sql: "DELETE FROM app_meta WHERE key = ?", arguments: [key])
            }
        }
    }

    // MARK: Запись

    /// Одна транзакция: всё внутри `body` и записи подписчиков фиксируются вместе или не фиксируются вовсе.
    @discardableResult
    public func write<T>(_ body: (NotesTransaction) throws -> T) throws -> T {
        let hooks = writeHooks.withLock { $0 }
        let addons = treeAddons.withLock { $0 }
        return try database.dbWriter.write { db in
            let transaction = NotesTransaction(db: db, clock: clock, keepsDeletionMarks: keepsDeletionMarks, treeAddons: addons)
            let result = try body(transaction)
            try transaction.giveEveryTouchedPageABlock()
            let changes = transaction.changes
            if !changes.isEmpty {
                for hook in hooks {
                    try hook.notesWillCommit(changes, in: transaction)
                }
            }
            try recordClock(in: db)
            return result
        }
    }

    // MARK: Часы после перезапуска

    static let clockMarkKey = "clock.latest"

    /// Последняя метка — в той же транзакции, что записи с ней: после перезапуска часы продолжат с неё.
    private func recordClock(in db: Database) throws {
        guard let issued = clock.lastIssued else { return }
        let isLater = recordedClock.withLock { recorded in
            guard recorded.map({ issued > $0 }) ?? true else { return false }
            recorded = issued
            return true
        }
        guard isLater else { return }
        try db.execute(sql: "INSERT INTO app_meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                       arguments: [Self.clockMarkKey, issued.description])
    }

    /// Отметка последней метки, а в базе, записанной до отметок, — самая поздняя метка записей
    /// (записи меток сортируются так же, как сами метки).
    static func latestStoredStamp(_ db: Database) throws -> HybridTimestamp? {
        if let mark = try String.fetchOne(db, sql: "SELECT value FROM app_meta WHERE key = ?", arguments: [clockMarkKey]) {
            return HybridTimestamp(mark)
        }
        let clockMaps = ["page", "block", "db_database", "db_property", "db_select_option", "db_relation_link", "db_view"].map { table in
            """
            SELECT max(clock.value) AS stamp
            FROM \(table), json_each(CASE WHEN json_valid(fieldClocks) THEN fieldClocks ELSE '{}' END) AS clock
            WHERE clock.type = 'text'
            """
        }
        let stamps = [("block", "textBaseClock"), ("page_tombstone", "erasedAt"), ("reminder_state", "doneClock"),
                      ("db_cell", "hlc"), ("db_row_order", "hlc")].map { "SELECT max(\($1)) AS stamp FROM \($0)" }
        let sql = "SELECT max(stamp) FROM (" + (clockMaps + stamps).joined(separator: " UNION ALL ") + ")"
        return try String.fetchOne(db, sql: sql).flatMap { HybridTimestamp($0) }
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
    /// Базы (004): схема, варианты, виды, ячейки, связи, места строк.
    public internal(set) var database = DatabaseChanges()

    public var isEmpty: Bool {
        pages.isEmpty && blocks.isEmpty && erasedPageIds.isEmpty && resolvedConflicts.isEmpty && reminderStates.isEmpty && database.isEmpty
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
    case invalidRecord(String)

    public var errorDescription: String? {
        switch self {
        case .pageNotFound(let id): "Страница \(id) не найдена"
        case .blockNotFound(let id): "Блок \(id) не найден"
        case .invalidPage(let reason): "Страница не записана: \(reason)"
        case .invalidBlock(let reason): "Блок не записан: \(reason)"
        case .corruptedRecord(let reason): "Запись в базе повреждена: \(reason)"
        case .invalidRecord(let reason): "Запись не сделана: \(reason)"
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
