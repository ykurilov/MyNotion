import AppKit
import Databases
import Formulas
import NotesCore
import XCTest

/// Проба формул (T006, research R20.3): 3 формулы «Задач» — `dateBetween` со сроком, `if` по флажку, `map` по связи —
/// на 10 000 строках пересчитываются на очереди записи пачками по 500 за ≤ 2 с, главный поток не замирает дольше 100 мс;
/// одна правка с пересчётом формул строки — ≤ 5 мс. Итоги пишутся в `db_computed` с сравнимыми колонками.
@MainActor
final class FormulaProbeTests: XCTestCase {
    static let fullBudgetSeconds = 2.0
    static let mainThreadBudgetMs = 100.0
    static let editBudgetMs = 5.0
    nonisolated static let batchSize = 500

    /// Цена вариантов запасного пути: пачки по 500 и по 2 000 строк, и правка ячейки с главного потока каждые 30 мс
    /// во время пересчёта — сколько она ждёт очередь записи (это и есть замирание окна при наборе).
    func testBatchSizeAgainstMainThreadEdits() async throws {
        let library = try DatabaseProbeLibrary.copy()
        defer { library.store.database.close(); try? FileManager.default.removeItem(at: library.folder) }
        let store = library.store, sample = library.sample
        let catalog = try DatabaseCatalog.read(sample.tasksId, in: store)
        let formulas = try ["Дней до срока", "Итог", "Проект (имя)"].map { name -> FullRecompute.Formula in
            let property = try XCTUnwrap(catalog.properties.first { $0.name == name })
            return FullRecompute.Formula(property: property, expression: try FormulaParser.parse(try XCTUnwrap(property.config["expression"]?.string)))
        }
        let rowIds = try XCTUnwrap(try ViewQuery.open(sample.tableViewId, in: store)).result.rowIds
        let projectTitle = sample.projectProperties["Название"]!.uuidString.lowercased()
        let note = sample.taskProperties["Заметка"]!
        var lines: [String] = []
        for batch in [500, 2_000] {
            let job = FullRecompute(rowIds: rowIds, formulas: formulas, catalog: catalog, projectTitle: projectTitle, store: store, batchSize: batch)
            var waits: [Double] = []
            var step = 0
            let editor = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { _ in
                MainActor.assumeIsolated {
                    step += 1
                    let row = rowIds[9_000 + step % 500]
                    waits.append((try? ProbeEditor.measure {
                        try store.write { tx in _ = try tx.setCell(rowId: row, propertyId: note, value: try JSONValue(encoding: InlineText("правка \(step)"))) }
                    }) ?? -1)
                }
            }
            let started = ContinuousClock.now
            let task = Task.detached(priority: .userInitiated) { try job.run() }
            _ = try await task.value
            let total = ContinuousClock.now - started
            editor.invalidate()
            let seconds = Double(total.components.seconds) + Double(total.components.attoseconds) / 1e18
            lines.append("Проба формул: пачки по \(batch) — \(String(format: "%.2f", seconds)) с (внутри транзакций \(Int(job.timing.inside)) мс); " +
                         "правка с главного потока во время пересчёта ждёт p95 \(ProbeEditor.format(ProbeEditor.p95(waits))) мс, худшая \(ProbeEditor.format(waits.max() ?? 0)) мс (\(waits.count) правок)")
        }
        print(lines.joined(separator: "\n"))
        add(XCTAttachment(string: lines.joined(separator: "\n")))
    }

    func testThreeFormulasOnTenThousandRowsWithinBudget() async throws {
        let library = try DatabaseProbeLibrary.copy()
        defer { library.store.database.close(); try? FileManager.default.removeItem(at: library.folder) }
        let store = library.store, sample = library.sample
        let catalog = try DatabaseCatalog.read(sample.tasksId, in: store)
        let formulas = try ["Дней до срока", "Итог", "Проект (имя)"].map { name -> (DatabaseProperty, FormulaExpression) in
            let property = try XCTUnwrap(catalog.properties.first { $0.name == name })
            return (property, try FormulaParser.parse(try XCTUnwrap(property.config["expression"]?.string)))
        }
        let rowIds = try XCTUnwrap(try ViewQuery.open(sample.tableViewId, in: store)).result.rowIds
        let projectTitle = sample.projectProperties["Название"]!.uuidString.lowercased()

        // Главный поток: отметки каждые 5 мс; самый долгий промежуток — замирание окна.
        let gaps = MainThreadGaps()
        let ticker = Timer.scheduledTimer(withTimeInterval: 0.005, repeats: true) { _ in gaps.tick() }
        let started = ContinuousClock.now
        let job = FullRecompute(rowIds: rowIds, formulas: formulas.map { FullRecompute.Formula(property: $0.0, expression: $0.1) },
                                catalog: catalog, projectTitle: projectTitle, store: store)
        let task = Task.detached(priority: .userInitiated) { try job.run() }
        let written = try await task.value
        let full = ContinuousClock.now - started
        ticker.invalidate()
        let longestGap = gaps.longest
        let fullSeconds = Double(full.components.seconds) + Double(full.components.attoseconds) / 1e18

        // Итоги сходятся с подсчётом генератора.
        let doneId = sample.taskProperties["Сделано"]!, resultId = sample.taskProperties["Итог"]!
        var mismatches = 0
        try store.write { tx in
            for row in rowIds.prefix(500) {
                let done = try tx.cell(rowId: row, propertyId: doneId)?.value?.bool ?? false
                let text = try tx.fetchTexts(sql: "SELECT value FROM db_computed WHERE rowId = ? AND propertyId = ?",
                                             arguments: [.text(row.uuidString.lowercased()), .text(resultId.uuidString.lowercased())]).first
                if text != (done ? #""Готово""# : #""В работе""#) { mismatches += 1 }
            }
        }

        // Одна правка флажка с пересчётом формул строки — одна транзакция.
        var edits: [Double] = []
        for step in 0..<25 {
            let row = rowIds[100 + step]
            let ms = try ProbeEditor.measure {
                try store.write { tx in
                    let old = try tx.cell(rowId: row, propertyId: doneId)?.value?.bool ?? false
                    try tx.setCell(rowId: row, propertyId: doneId, value: .bool(!old))
                    _ = try Self.recompute([row], formulas: formulas, catalog: catalog, projectTitle: projectTitle, in: tx)
                }
            }
            if step >= 5 { edits.append(ms) }
        }

        let summary = """
            Проба формул: 3 формулы × \(rowIds.count) строк — \(String(format: "%.2f", fullSeconds)) с на очереди записи пачками по \(Self.batchSize) \
            (предел 2 с), записано итогов \(written); главный поток замирал до \(ProbeEditor.format(longestGap)) мс (предел 100); \
            расхождений с генератором \(mismatches) из 500; внутри транзакций \(Int(job.timing.inside)) мс, транзакции целиком \(Int(job.timing.total)) мс
            Проба формул: правка флажка с пересчётом строки p95 \(ProbeEditor.format(ProbeEditor.p95(edits))) мс, медиана \(ProbeEditor.format(ProbeEditor.median(edits))) мс (предел 5)
            """
        print(summary)
        add(XCTAttachment(string: summary))
        XCTAssertEqual(written, rowIds.count * formulas.count)
        XCTAssertLessThanOrEqual(fullSeconds, Self.fullBudgetSeconds, "Полный пересчёт дольше 2 с")
        XCTAssertLessThanOrEqual(longestGap, Self.mainThreadBudgetMs, "Главный поток замирал дольше 100 мс")
        XCTAssertEqual(mismatches, 0, "Итог формулы «Итог» не сходится")
        XCTAssertLessThanOrEqual(ProbeEditor.p95(edits), Self.editBudgetMs, "Правка с пересчётом: p95 больше 5 мс")
    }

    /// Пересчитать формулы строк `rows` в транзакции: прочитать значения, нужные формулам (свои ячейки, связи и названия
    /// связанных строк), вычислить, записать `db_computed`.
    nonisolated static func recompute(_ rows: [UUID], formulas: [(DatabaseProperty, FormulaExpression)], catalog: DatabaseCatalog,
                                      projectTitle: String, in tx: NotesTransaction) throws -> Int {
        // Читаются только свойства, от которых зависят формулы (их знает дерево формулы, research R6).
        let needed = formulas.reduce(into: Set<String>()) { $0.formUnion($1.1.referencedProperties) }
        let context = try ProbeFormulaContext(rows: rows, catalog: catalog, projectTitle: projectTitle, properties: needed, in: tx)
        var written = 0
        for row in rows {
            for (property, expression) in formulas {
                let value = FormulaEvaluator.evaluate(expression, row: row, context: context)
                let (json, text, number) = Self.stored(value)
                try tx.executeCached(sql: """
                    INSERT INTO db_computed (rowId, propertyId, value, sortText, sortNumber, searchText, isLive) VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(rowId, propertyId) DO UPDATE SET value = excluded.value, sortText = excluded.sortText,
                        sortNumber = excluded.sortNumber, searchText = excluded.searchText, isLive = excluded.isLive
                    """, arguments: [.text(row.uuidString.lowercased()), .text(property.id.uuidString.lowercased()), json.map(SQLValue.text) ?? .null,
                                     text.map(SQLValue.text) ?? .null, number.map(SQLValue.real) ?? .null, text.map(SQLValue.text) ?? .null,
                                     .integer(expression.isLive ? 1 : 0)])
                written += 1
            }
        }
        return written
    }

    nonisolated static func stored(_ value: FormulaValue) -> (json: String?, text: String?, number: Double?) {
        let none: (json: String?, text: String?, number: Double?) = (nil, nil, nil)
        switch value {
        case .number(let number): return (JSONValue.number(number).jsonText, none.text, number)
        case .text(let text): return (JSONValue.string(text).jsonText, SortableText.make(text), none.number)
        case .bool(let flag): return (JSONValue.bool(flag).jsonText, none.text, flag ? 1 : 0)
        case .date(let date):
            return (JSONValue.object(["start": .string(ISO8601DateFormatter().string(from: date.start))]).jsonText, none.text, date.start.timeIntervalSince1970)
        case .list(let items):
            let texts = items.compactMap(\.text)
            return (JSONValue.array(texts.map(JSONValue.string)).jsonText, texts.first.map(SortableText.make), none.number)
        default: return none
        }
    }
}

/// Полный пересчёт: пачками по `batchSize` строк, каждая пачка — своя транзакция на очереди записи.
struct FullRecompute: Sendable {
    struct Formula: Sendable {
        let property: DatabaseProperty
        let expression: FormulaExpression
    }

    let rowIds: [UUID]
    let formulas: [Formula]
    let catalog: DatabaseCatalog
    let projectTitle: String
    let store: NotesStore
    var batchSize = FormulaProbeTests.batchSize

    static func milliseconds(_ action: () throws -> Void) rethrows -> Double {
        let start = ContinuousClock.now
        try action()
        let duration = ContinuousClock.now - start
        return Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }

    /// Время по частям: работа внутри транзакций и транзакции целиком (с фиксацией на диске).
    final class Timing: @unchecked Sendable { var inside = 0.0, total = 0.0 }
    let timing = Timing()

    func run() throws -> Int {
        var count = 0
        let pairs = formulas.map { ($0.property, $0.expression) }
        for start in stride(from: 0, to: rowIds.count, by: batchSize) {
            let batch = Array(rowIds[start..<min(start + batchSize, rowIds.count)])
            var inside = 0.0
            timing.total += try Self.milliseconds {
                count += try store.write { tx in
                    var written = 0
                    inside = try Self.milliseconds {
                        written = try FormulaProbeTests.recompute(batch, formulas: pairs, catalog: catalog, projectTitle: projectTitle, in: tx)
                    }
                    return written
                }
            }
            timing.inside += inside
        }
        return count
    }
}

/// Самый долгий промежуток между отметками главного потока, мс.
final class MainThreadGaps: @unchecked Sendable {
    private(set) var longest = 0.0
    private var last = ContinuousClock.now

    func tick() {
        let now = ContinuousClock.now
        let gap = now - last
        longest = max(longest, Double(gap.components.seconds) * 1_000 + Double(gap.components.attoseconds) / 1e15)
        last = now
    }
}

/// Значения для формул пачки строк — одно чтение на пачку.
struct ProbeFormulaContext: FormulaContext {
    var values: [UUID: [String: FormulaValue]] = [:]
    let now = Date()
    let calendar = Calendar.current

    init(rows: [UUID], catalog: DatabaseCatalog, projectTitle: String, properties: Set<String>, in tx: NotesTransaction) throws {
        let ids = rows.map { SQLValue.text($0.uuidString.lowercased()) }
        let marks = Array(repeating: "?", count: rows.count).joined(separator: ",")
        let kinds = Dictionary(uniqueKeysWithValues: catalog.properties.map { ($0.id.uuidString.lowercased(), $0.kind) })
        let wanted = properties.sorted().map(SQLValue.text)
        let wantedMarks = Array(repeating: "?", count: wanted.count).joined(separator: ",")
        for line in try tx.fetchTexts(sql: """
            SELECT rowId || char(9) || propertyId || char(9) || value FROM db_cell
            WHERE rowId IN (\(marks)) AND propertyId IN (\(wantedMarks)) AND value IS NOT NULL
            """, arguments: ids + wanted) {
            let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard parts.count == 3, let row = UUID(uuidString: parts[0]), let kind = kinds[parts[1]], let json = FastJSON.parse(parts[2]) else { continue }
            values[row, default: [:]][parts[1]] = Self.formulaValue(json, kind: kind)
        }
        // Связь «Проект»: страницы цели и их названия.
        for property in catalog.properties where property.kind == .relation && properties.contains(property.id.uuidString.lowercased()) {
            let propertyText = property.id.uuidString.lowercased()
            for line in try tx.fetchTexts(sql: """
                SELECT l.rowId || char(9) || l.targetRowId || char(9) || t.title FROM db_relation_link l JOIN page t ON t.id = l.targetRowId
                WHERE l.propertyId = ? AND l.rowId IN (\(marks)) AND l.isPresent = 1 ORDER BY l.sortKey
                """, arguments: [.text(propertyText)] + ids) {
                let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
                guard parts.count == 3, let row = UUID(uuidString: parts[0]), let target = UUID(uuidString: parts[1]) else { continue }
                var list = values[row]?[propertyText]?.list ?? []
                list.append(.page(target))
                values[row, default: [:]][propertyText] = .list(list)
                values[target, default: [:]][projectTitle] = .text(parts[2])
            }
        }
    }

    static func formulaValue(_ json: JSONValue, kind: PropertyKind) -> FormulaValue {
        switch kind {
        case .date:
            guard let start = json["start"]?.string.flatMap({ DateText.parse($0, timeZone: json["timeZone"]?.string) }) else { return .empty }
            return .date(FormulaDate(start: start, hasTime: json["hasTime"]?.bool ?? false))
        case .checkbox: return .bool(json.bool ?? false)
        case .number: return json.number.map(FormulaValue.number) ?? .empty
        default: return json.string.map(FormulaValue.text) ?? .empty
        }
    }

    func value(ofProperty propertyId: String, row rowId: UUID) -> FormulaValue {
        values[rowId]?[propertyId] ?? .empty
    }
}
