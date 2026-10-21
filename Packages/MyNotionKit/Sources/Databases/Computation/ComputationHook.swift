import Foundation
import Formulas
import GRDB
import NotesCore
import Synchronization

/// Подписчик записи (research R6, R21, contracts/formulas.md, «Пересчёт»): правка значения пересчитывает зависящие
/// формулы своей строки и строк, связанных с ней, в той же транзакции; новая или изменённая формула, смена типа,
/// удаление свойства и переименование варианта, от которых зависят формулы, — полный пересчёт базы в фоне после фиксации.
/// Переименование свойства формул не трогает: в них хранятся id.
public final class ComputationHook: NotesWriteHook {
    let store: NotesStore
    let queue: FormulaRecomputeQueue?
    let now: @Sendable () -> Date
    let calendar: Calendar
    /// Схема зависимостей по зафиксированному состоянию; сбрасывается правкой схемы.
    private let cachedGraph = Mutex<ComputationGraph?>(nil)

    public init(store: NotesStore, queue: FormulaRecomputeQueue?, now: @escaping @Sendable () -> Date = Date.init, calendar: Calendar = .current) {
        self.store = store
        self.queue = queue
        self.now = now
        self.calendar = calendar
    }

    public func notesWillCommit(_ changes: NotesChanges, in transaction: NotesTransaction) throws {
        let db = transaction.database
        let schemaChanged = !changes.database.properties.isEmpty || !changes.database.options.isEmpty || !changes.database.databases.isEmpty
        let graph: ComputationGraph
        if schemaChanged {
            // Схема этой транзакции может откатиться: в кэш не кладём.
            cachedGraph.withLock { $0 = nil }
            graph = try ComputationGraph.read(in: db)
        } else if let known = cachedGraph.withLock({ $0 }) {
            graph = known
        } else {
            graph = try ComputationGraph.read(in: db)
            cachedGraph.withLock { $0 = graph }
        }
        if schemaChanged, let queue { scheduleFullRecompute(changes, graph: graph, queue: queue, in: transaction) }
        try recomputeRows(changes, graph: graph, in: db, transaction: transaction)
    }

    // MARK: Строки — в транзакции правки

    private func recomputeRows(_ changes: NotesChanges, graph: ComputationGraph, in db: Database, transaction: NotesTransaction) throws {
        /// База → строки, чьи формулы пересчитать; `order` — порядок баз по кругам: читатели — после тех, кого читают.
        var dirty: [UUID: Set<UUID>] = [:] {
            didSet { for key in dirty.keys where !order.contains(key) { order.append(key) } }
        }
        var order: [UUID] = []
        /// База → строки, у которых поменялись свойства (`nil` — неизвестно какие: новая строка, корзина).
        var touched: [UUID: [UUID: Set<UUID>?]] = [:]
        func touch(_ databaseId: UUID, _ row: UUID, _ property: UUID?) {
            var rows = touched[databaseId] ?? [:]
            if let property, let known = rows[row] { rows[row] = known.map { $0.union([property]) } } else if let property, rows[row] == nil {
                rows[row] = .some([property])
            } else { rows[row] = .some(nil) }
            touched[databaseId] = rows
        }
        var databaseOf: [UUID: UUID?] = [:]
        func database(ofProperty id: UUID) throws -> UUID? {
            if let known = databaseOf[id] { return known }
            let found = try graph.databaseOfProperty[id] ?? transaction.property(id)?.databaseId
            databaseOf[id] = found
            return found
        }

        for cell in changes.database.cells {
            guard let databaseId = try database(ofProperty: cell.propertyId) else { continue }
            touch(databaseId, cell.rowId, cell.propertyId)
        }
        for change in changes.pages {
            guard let parent = change.page.parentId, change.isNew || !change.changedFields.isDisjoint(with: [.title, .trashedAt, .placement]),
                  try transaction.isDatabase(parent) else { continue }
            if change.isNew || change.changedFields.contains(.trashedAt) || change.changedFields.contains(.placement) {
                touch(parent, change.page.id, nil)
            } else if let title = (graph.formulas[parent]?.catalog ?? (try? DatabaseCatalog.read(parent, in: db)))?.titleProperty {
                touch(parent, change.page.id, title.id)
            }
        }
        for change in changes.database.relationLinks {
            let link = change.record
            guard let relation = try transaction.property(link.propertyId) else { continue }
            touch(relation.databaseId, link.rowId, relation.id)
            if let paired = relation.pairedRelation, let target = relation.relationTarget { touch(target, link.targetRowId, paired) }
        }

        // Круги: свои строки, затем строки, читающие их по связям (итог формулы — тоже правка для читателей).
        for _ in 0..<4 where !touched.isEmpty {
            for (databaseId, rows) in touched {
                if let formulas = graph.formulas[databaseId] {
                    for (row, properties) in rows where properties.map({ !$0.isDisjoint(with: formulas.ownDependencies) }) ?? true || formulas.dependsOnRowTimes {
                        dirty[databaseId, default: []].insert(row)
                    }
                }
            }
            var next: [UUID: [UUID: Set<UUID>?]] = [:]
            for (databaseId, rows) in touched {
                let changed = rows.values.contains { $0 == nil } ? nil : rows.values.reduce(into: Set<UUID>()) { $0.formUnion($1 ?? []) }
                    .union(dirty[databaseId] == nil ? [] : graph.formulas[databaseId]?.formulaIds ?? [])
                for (relation, readers) in graph.readers(of: databaseId, changed: changed) {
                    let linked = try ComputationGraph.rows(linkingTo: Set(rows.keys), through: relation, in: db)
                    for row in linked where dirty[relation.databaseId]?.contains(row) != true {
                        next[relation.databaseId, default: [:]][row] = .some(readers.formulaIds)
                    }
                }
            }
            // Строки читателей пересчитываются в этом же круге.
            for (databaseId, rows) in next { dirty[databaseId, default: []].formUnion(rows.keys) }
            touched = next.filter { databaseId, _ in !graph.readers(of: databaseId, changed: graph.formulas[databaseId]?.formulaIds).isEmpty }
        }

        for databaseId in order {
            guard let rows = dirty[databaseId], let formulas = graph.formulas[databaseId], !formulas.isEmpty else { continue }
            let alive = try Self.aliveRows(Array(rows), of: databaseId, in: db)
            try FormulaRecompute(store: store, catalog: formulas.catalog, now: now, calendar: calendar).recompute(rows: alive, in: transaction)
        }
    }

    /// Строки базы, которые есть и не в корзине.
    static func aliveRows(_ rows: [UUID], of databaseId: UUID, in db: Database) throws -> [UUID] {
        guard !rows.isEmpty else { return [] }
        let marks = Array(repeating: "?", count: rows.count).joined(separator: ",")
        return try String.fetchAll(db, sql: "SELECT id FROM page WHERE parentId = ? AND trashedAt IS NULL AND id IN (\(marks))",
                                   arguments: StatementArguments([databaseId.databaseText] + rows.map(\.databaseText))).compactMap(UUID.init(uuidString:))
    }

    // MARK: Полный пересчёт — в фоне после фиксации

    private func scheduleFullRecompute(_ changes: NotesChanges, graph: ComputationGraph, queue: FormulaRecomputeQueue, in transaction: NotesTransaction) {
        var jobs: [UUID: Set<UUID>?] = [:]
        func add(_ databaseId: UUID, _ properties: Set<UUID>?) {
            if let known = jobs[databaseId] { jobs[databaseId] = known.flatMap { known in properties.map { known.union($0) } } } else { jobs[databaseId] = .some(properties) }
        }
        /// Свойства, от изменения которых зависят итоги формул (тип, настройки, удаление, названия вариантов).
        var changedValues: [UUID: Set<UUID>] = [:]
        for change in changes.database.properties {
            let property = change.record
            if property.kind == .formula, change.isNew || change.changedFields.contains(.typeAndConfig) || change.changedFields.contains(.deletedAt) {
                if property.deletedAt == nil { add(property.databaseId, [property.id]) }
                changedValues[property.databaseId, default: []].insert(property.id)
            } else if !change.isNew, change.changedFields.contains(.typeAndConfig) || change.changedFields.contains(.deletedAt) {
                changedValues[property.databaseId, default: []].insert(property.id)
            }
        }
        for change in changes.database.options where !change.isNew && (change.changedFields.contains(.name) || change.changedFields.contains(.deletedAt)) {
            if let databaseId = graph.databaseOfProperty[change.record.propertyId] ?? (try? transaction.property(change.record.propertyId))?.databaseId {
                changedValues[databaseId, default: []].insert(change.record.propertyId)
            }
        }
        for (databaseId, properties) in changedValues {
            // Удалённое свойство уже не в схеме — его id числится среди «чужих».
            if let formulas = graph.formulas[databaseId],
               !formulas.ownDependencies.isDisjoint(with: properties) || !formulas.foreignDependencies.isDisjoint(with: properties) {
                add(databaseId, properties)
            }
            for (relation, readers) in graph.readers(of: databaseId, changed: properties) { add(relation.databaseId, readers.formulaIds) }
        }
        guard !jobs.isEmpty else { return }
        let scheduled = jobs
        transaction.database.afterNextTransaction { _ in
            for (databaseId, properties) in scheduled { queue.enqueue(databaseId, propertyIds: properties) }
        }
    }
}
