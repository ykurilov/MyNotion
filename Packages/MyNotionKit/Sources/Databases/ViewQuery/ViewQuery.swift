import Foundation
import GRDB
import NotesCore
import Synchronization

/// Открытый вид: схема базы, запись вида и итог его запроса.
public struct OpenedView: Sendable {
    public var catalog: DatabaseCatalog
    public var view: DatabaseView
    public var result: ViewQueryResult
}

/// Запрос вида к хранилищу (research R3): одно чтение — схема, вид, строки по порядку.
public enum ViewQuery {
    /// Открыть вид: его фильтр, сортировки и группа; `search` — поиск в базе.
    public static func open(_ viewId: UUID, in store: NotesStore, search: String? = nil, now: Date = Date()) throws -> OpenedView? {
        try store.database.dbWriter.read { db in
            guard let view = try Row.fetchOne(db, sql: "SELECT * FROM db_view WHERE id = ?", arguments: [viewId.databaseText])
                .map(DatabaseView.init(row:)) else { return nil }
            let catalog = try DatabaseCatalog.read(view.databaseId, in: db)
            var spec = ViewQuerySpec(view: view, search: search)
            if search != nil { spec.searchPropertyIds = Self.visiblePropertyIds(of: view, catalog: catalog) }
            var query = ViewQuerySQL(spec: spec, catalog: catalog, now: now)
            return OpenedView(catalog: catalog, view: view, result: try query.fetch(in: db))
        }
    }

    /// Первый вид базы (по порядку вкладок).
    public static func firstViewId(of databaseId: UUID, in store: NotesStore) throws -> UUID? {
        try store.database.dbWriter.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM db_view WHERE databaseId = ? ORDER BY sortKey, id LIMIT 1",
                                arguments: [databaseId.databaseText]).flatMap(UUID.init(uuidString:))
        }
    }

    /// Строки по готовому описанию запроса.
    public static func rows(_ spec: ViewQuerySpec, catalog: DatabaseCatalog, in store: NotesStore, now: Date = Date()) throws -> ViewQueryResult {
        try store.database.dbWriter.read { db in
            var query = ViewQuerySQL(spec: spec, catalog: catalog, now: now)
            return try query.fetch(in: db)
        }
    }

    /// План SQLite запроса (`EXPLAIN QUERY PLAN`): строки «SEARCH …» / «SCAN …».
    public static func plan(_ spec: ViewQuerySpec, catalog: DatabaseCatalog, in store: NotesStore, now: Date = Date()) throws -> [String] {
        try store.database.dbWriter.read { db in
            var query = ViewQuerySQL(spec: spec, catalog: catalog, now: now)
            let (sql, arguments) = query.build()
            return try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql, arguments: arguments).map { $0["detail"] as String }
        }
    }

    /// Видимые свойства вида по порядку колонок; свойства не из списка — видимые, в конце (data-model.md, `columns`).
    public static func visiblePropertyIds(of view: DatabaseView, catalog: DatabaseCatalog) -> [UUID] {
        var listed: [UUID] = []
        var hidden: Set<UUID> = []
        for column in view.columns.array ?? [] {
            guard let id = column["propertyId"]?.string.flatMap(UUID.init(uuidString:)), catalog.propertiesById[id] != nil else { continue }
            if column["isVisible"]?.bool == false { hidden.insert(id) } else { listed.append(id) }
        }
        let rest = catalog.properties.map(\.id).filter { !listed.contains($0) && !hidden.contains($0) }
        return listed + rest
    }
}

/// Последний запрос вида выигрывает (research R3: поиск на каждый символ — новый запрос, прежний отменяется):
/// запрос с устаревшим билетом не отдаёт итог.
public final class LatestViewQuery: Sendable {
    public struct Ticket: Sendable, Hashable { let number: Int }

    public let store: NotesStore
    private let current = Mutex(0)

    public init(store: NotesStore) {
        self.store = store
    }

    /// Новый запрос: все прежние билеты устарели.
    public func begin() -> Ticket {
        Ticket(number: current.withLock { $0 += 1; return $0 })
    }

    public func isCurrent(_ ticket: Ticket) -> Bool { current.withLock { $0 == ticket.number } }

    /// Выполнить на очереди чтения; `nil` — пока шёл запрос (или до него), начался новый.
    public func run(_ spec: ViewQuerySpec, catalog: DatabaseCatalog, ticket: Ticket, now: Date = Date()) async throws -> ViewQueryResult? {
        guard isCurrent(ticket) else { return nil }
        let store = store
        let result = try await Task.detached(priority: .userInitiated) {
            try ViewQuery.rows(spec, catalog: catalog, in: store, now: now)
        }.value
        return isCurrent(ticket) ? result : nil
    }
}
