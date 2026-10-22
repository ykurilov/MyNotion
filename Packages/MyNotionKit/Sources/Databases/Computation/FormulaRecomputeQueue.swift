import Foundation
import NotesCore
import Synchronization

/// Очередь полных пересчётов в фоне (research R21): новая формула или сводка, их правка, смена типа или удаление свойства,
/// от которого они зависят, корзина базы-цели, «живые» формулы раз в минуту, первое заполнение. Сводки — раньше формул:
/// формула может читать сводку. Запросы к одной базе склеиваются;
/// пересчёт идёт на служебном потоке, пока ячейки показывают прежний итог.
public final class FormulaRecomputeQueue: Sendable {
    public let store: NotesStore
    let now: @Sendable () -> Date
    let calendar: Calendar
    private let queue = DispatchQueue(label: "MyNotion.formulas.recompute", qos: .utility)
    /// База → свойства для пересчёта (`nil` — все формулы базы).
    private let pending = Mutex<[UUID: Set<UUID>?]>([:])
    private let finished = Mutex<(@Sendable (UUID, FormulaRecompute.Report) -> Void)?>(nil)

    public init(store: NotesStore, now: @escaping @Sendable () -> Date = Date.init, calendar: Calendar = .current) {
        self.store = store
        self.now = now
        self.calendar = calendar
    }

    /// После каждого пересчёта базы (на служебном потоке): перерисовать её виды.
    public func onFinished(_ handler: @escaping @Sendable (UUID, FormulaRecompute.Report) -> Void) {
        finished.withLock { $0 = handler }
    }

    /// Пересчитать формулы `propertyIds` базы (и зависящие от них); `nil` — все.
    public func enqueue(_ databaseId: UUID, propertyIds: Set<UUID>? = nil) {
        let isFirst = pending.withLock { pending -> Bool in
            let isFirst = pending[databaseId] == nil
            if isFirst { pending[databaseId] = .some(propertyIds) } else if let known = pending[databaseId]!, let propertyIds {
                pending[databaseId] = .some(known.union(propertyIds))
            } else { pending[databaseId] = .some(nil) }
            return isFirst
        }
        guard isFirst else { return }
        queue.async { [self] in run(databaseId) }
    }

    private func run(_ databaseId: UUID) {
        guard let entry = pending.withLock({ $0.removeValue(forKey: databaseId) }) else { return }
        do {
            let rollups = try store.database.dbWriter.read { db in
                try RollupRecompute(catalog: DatabaseCatalog.read(databaseId, in: db), propertyIds: entry, calendar: calendar, in: db)
            }
            try rollups.recomputeAll(in: store)
            let recompute = try FormulaRecompute(store: store, databaseId: databaseId, propertyIds: entry.map { $0.union(rollups.propertyIds) },
                                                 now: now, calendar: calendar)
            let report = try recompute.recomputeAll()
            finished.withLock { $0 }?(databaseId, report)
        } catch {
            // База удалена или запись не удалась: следующая правка поставит пересчёт снова.
        }
    }

    /// Работа на служебном потоке очереди между пересчётами (тесты: занять очередь).
    func enqueueBarrier(_ work: @escaping @Sendable () -> Void) { queue.async(execute: work) }

    /// Дождаться, пока очередь опустеет (тесты, замеры, закрытие).
    public func waitUntilIdle() {
        while true {
            queue.sync {}
            if pending.withLock({ $0.isEmpty }) { return }
        }
    }

    /// Первое заполнение: базы, где у формул и сводок нет итогов части строк (после миграции, восстановления, синхронизации),
    /// пересчитываются в фоне. Сама проверка — тоже в фоне.
    public func fillMissing() {
        queue.async { [self] in
            let missing = (try? store.database.dbWriter.read { db in
                try String.fetchAll(db, sql: """
                    SELECT DISTINCT p.databaseId FROM db_property p JOIN page r ON r.parentId = p.databaseId AND r.trashedAt IS NULL
                    WHERE p.type IN ('formula', 'rollup') AND p.deletedAt IS NULL
                      AND NOT EXISTS (SELECT 1 FROM db_computed c WHERE c.rowId = r.id AND c.propertyId = p.id)
                    """).compactMap(UUID.init(uuidString:))
            }) ?? []
            for databaseId in missing { enqueue(databaseId) }
        }
    }
}
