import Foundation
import Formulas
import GRDB
import NotesCore

/// Пересчёт формул базы (research R6, R21). Две дороги:
/// - правка строки — `recompute(rows:in:)` в той же транзакции (подписчик правок US5);
/// - новая формула, смена типа, первое заполнение — `recomputeAll()` в фоне: значения читаются и формулы вычисляются
///   на чтении (WAL), итоги пишутся короткими пачками; между пачками очередь записи свободна, правки с главного потока
///   идут первыми. Строку, поправленную после чтения, пачка не трогает — она пересчитывается следующим кругом.
///   До готовности в ячейке — прежний итог.
public struct FormulaRecompute: Sendable {
    public struct Formula: Sendable {
        public let property: DatabaseProperty
        public let expression: FormulaExpression
    }

    /// Итог полного пересчёта.
    public struct Report: Sendable {
        public var rows = 0
        public var written = 0
        /// Строк, пропущенных пачкой (их правили) и пересчитанных заново.
        public var retried = 0
        public var writeBatches = 0
        /// Самая долгая запись пачки, мс (столько ждёт правка в худшем случае).
        public var longestWriteMs = 0.0
    }

    public let store: NotesStore
    public let databaseId: UUID
    public let formulas: [Formula]
    let catalog: DatabaseCatalog
    let now: @Sendable () -> Date
    let calendar: Calendar

    /// Формулы базы (все или `propertyIds`); формула с ошибкой разбора пропускается — её не сохранит редактор.
    public init(store: NotesStore, databaseId: UUID, propertyIds: Set<UUID>? = nil, now: @escaping @Sendable () -> Date = Date.init,
                calendar: Calendar = .current) throws {
        self.store = store
        self.databaseId = databaseId
        self.now = now
        self.calendar = calendar
        catalog = try DatabaseCatalog.read(databaseId, in: store)
        formulas = catalog.properties.filter { $0.kind == .formula && (propertyIds?.contains($0.id) ?? true) }.compactMap { property in
            guard let text = property.config["expression"]?.string, let expression = try? FormulaParser.parse(text) else { return nil }
            return Formula(property: property, expression: expression)
        }
    }

    private var needed: Set<String> { formulas.reduce(into: []) { $0.formUnion($1.expression.referencedProperties) } }

    /// Вычислить итоги строк по прочитанным значениям.
    func evaluate(_ rows: [UUID], inputs: FormulaInputs) -> [ComputedValue] {
        rows.flatMap { row in
            formulas.map { formula in
                let value = FormulaEvaluator.evaluate(formula.expression, row: row, context: inputs)
                return ComputedValue(rowId: row, propertyId: formula.property.id, value: FormulaInputs.json(value, calendar: calendar),
                                     isLive: formula.expression.isLive)
            }
        }
    }

    /// Правка строк: прочитать, вычислить и записать в транзакции правки.
    public func recompute(rows: [UUID], in transaction: NotesTransaction) throws {
        guard !formulas.isEmpty, !rows.isEmpty else { return }
        let inputs = try FormulaInputs(rows: rows, needed: needed, catalog: catalog, now: now(), calendar: calendar, in: transaction.database)
        try ComputedWriter.write(evaluate(rows, inputs: inputs), in: transaction)
    }

    /// Полный пересчёт строк базы в фоне (вызывать не с главного потока). `readBatch` — строк на чтение,
    /// `writeBatch` — строк на одну короткую запись.
    public func recomputeAll(readBatch: Int = 500, writeBatch: Int = 50) throws -> Report {
        guard !formulas.isEmpty else { return Report() }
        return try store.database.withoutAutoCheckpoint { try recomputeAllRows(readBatch: readBatch, writeBatch: writeBatch) }
    }

    private func recomputeAllRows(readBatch: Int, writeBatch: Int) throws -> Report {
        var report = Report()
        var pending = try store.database.dbWriter.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM page WHERE parentId = ? AND trashedAt IS NULL ORDER BY sortKey",
                                arguments: [databaseId.databaseText]).compactMap(UUID.init(uuidString:))
        }
        report.rows = pending.count
        var round = 0
        while !pending.isEmpty, round < 5 {
            var skipped: [UUID] = []
            for start in stride(from: 0, to: pending.count, by: readBatch) {
                let rows = Array(pending[start..<min(start + readBatch, pending.count)])
                let (values, stamps) = try store.database.dbWriter.read { db -> ([ComputedValue], [UUID: String]) in
                    let inputs = try FormulaInputs(rows: rows, needed: needed, catalog: catalog, now: now(), calendar: calendar, in: db)
                    return (evaluate(rows, inputs: inputs), inputs.stamps)
                }
                let perRow = Dictionary(grouping: values, by: \.rowId)
                for chunkStart in stride(from: 0, to: rows.count, by: writeBatch) {
                    let chunk = rows[chunkStart..<min(chunkStart + writeBatch, rows.count)]
                    let chunkValues = chunk.flatMap { perRow[$0] ?? [] }
                    let started = ContinuousClock.now
                    let missed = try store.database.dbWriter.write { db in
                        try ComputedWriter.write(chunkValues, readStamps: stamps, in: db)
                    }
                    let took = ContinuousClock.now - started
                    report.longestWriteMs = max(report.longestWriteMs,
                                                Double(took.components.seconds) * 1_000 + Double(took.components.attoseconds) / 1e15)
                    report.writeBatches += 1
                    report.written += chunkValues.filter { !missed.contains($0.rowId) }.count
                    skipped += missed
                }
            }
            report.retried += skipped.count
            pending = skipped
            round += 1
        }
        return report
    }
}
