import AppKit
import Databases
import Formulas
import NotesCore
import XCTest

/// Замеры формул US5 (T056, research R21) на эталоне баз («Задачи» 10 000 строк): новая формула считается в фоне
/// пачками, правка в это время ждёт ≤ 50 мс p95, итог сходится с подсчётом «в лоб»; первое заполнение `db_computed`
/// ≤ 5 с в фоне; правка ячейки с пересчётом через подписчика записи ≤ 50 мс p95 (SC-303); открытие «Задач» с
/// сортировкой по формуле ≤ 50 мс p95 (SC-301).
@MainActor
final class FormulaBudgetTests: XCTestCase {
    static let editWaitBudgetMs = 50.0
    static let firstFillBudgetSeconds = 5.0
    static let openBudgetMs = 50.0

    private func library() throws -> (folder: URL, store: NotesStore, sample: DatabaseSampleGenerator.Sample, queue: FormulaRecomputeQueue) {
        let library = try DatabaseProbeLibrary.copy()
        let queue = FormulaRecomputeQueue(store: library.store)
        library.store.addWriteHook(CellIndexer())
        library.store.addWriteHook(ComputationHook(store: library.store, queue: queue))
        return (library.folder, library.store, library.sample, queue)
    }

    /// Дождаться пустой очереди, не держа главный поток (таймеры правок идут).
    private func waitIdle(_ queue: FormulaRecomputeQueue) async {
        await Task.detached { queue.waitUntilIdle() }.value
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    func testNewFormulaInBackgroundKeepsEditsResponsive() async throws {
        let (folder, store, sample, queue) = try library()
        defer { store.database.close(); try? FileManager.default.removeItem(at: folder) }
        let done = sample.taskProperties["Сделано"]!, hours = sample.taskProperties["Часы"]!
        let rowIds = try XCTUnwrap(try ViewQuery.open(sample.tableViewId, in: store)).result.rowIds
        let operations = DatabaseOperations(store: store)
        let property = try operations.addProperty(to: sample.tasksId, name: "Оценка часов", kind: .formula)

        let gaps = MainThreadGaps()
        let ticker = Timer.scheduledTimer(withTimeInterval: 0.005, repeats: true) { _ in gaps.tick() }
        var waits: [Double] = []
        var step = 0
        let editor = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { _ in
            MainActor.assumeIsolated {
                step += 1
                let row = rowIds[(step * 37) % rowIds.count]
                waits.append((try? ProbeEditor.measure {
                    try store.write { tx in
                        let old = try tx.cell(rowId: row, propertyId: done)?.value?.bool ?? false
                        try tx.setCell(rowId: row, propertyId: done, value: .bool(!old))
                    }
                }) ?? -1)
            }
        }
        let started = ContinuousClock.now
        let saveMs = try ProbeEditor.measure { _ = try operations.setFormula(property.id, display: #"if(prop("Сделано"), prop("Часы") * 2, prop("Часы") + 1)"#) }
        await waitIdle(queue)
        let total = Self.seconds(ContinuousClock.now - started)
        editor.invalidate()
        ticker.invalidate()

        var mismatches: [String] = []
        try store.write { tx in
            for row in rowIds {
                let isDone = try tx.cell(rowId: row, propertyId: done)?.value?.bool ?? false
                let value = try tx.cell(rowId: row, propertyId: hours)?.value?.number
                let expected = value.map { JSONValue.number(isDone ? $0 * 2 : $0 + 1).jsonText }
                let stored = try tx.fetchTexts(sql: "SELECT value FROM db_computed WHERE rowId = ? AND propertyId = ?",
                                               arguments: [.text(row.uuidString.lowercased()), .text(property.id.uuidString.lowercased())]).first
                if stored != expected { mismatches.append("\(row): \(stored ?? "нет") ≠ \(expected ?? "пусто")") }
            }
        }
        let summary = """
            Новая формула на \(rowIds.count) строках: «Готово» \(ProbeEditor.format(saveMs)) мс (пересчёт — в фоне), до готовности \
            \(String(format: "%.2f", total)) с; правка во время пересчёта ждёт p95 \(ProbeEditor.format(ProbeEditor.p95(waits))) мс, \
            медиана \(ProbeEditor.format(ProbeEditor.median(waits))), худшая \(ProbeEditor.format(waits.max() ?? 0)) мс (\(waits.count) правок, предел 50); \
            главный поток замирал до \(ProbeEditor.format(gaps.longest)) мс; итог сошёлся «в лоб» у \(rowIds.count - mismatches.count) из \(rowIds.count)
            """
        print(summary)
        add(XCTAttachment(string: summary + "\n" + mismatches.prefix(5).joined(separator: "\n")))
        XCTAssertLessThanOrEqual(ProbeEditor.p95(waits), Self.editWaitBudgetMs, "Правка во время пересчёта ждёт больше 50 мс (p95)")
        XCTAssertGreaterThan(waits.count, 5, "Пересчёт закончился раньше, чем главный поток успел править")
        XCTAssertTrue(mismatches.isEmpty, "Итог не сходится: \(mismatches.prefix(3))")
        XCTAssertLessThan(saveMs, 100, "«Готово» держит окно дольше 100 мс")
    }

    func testFirstFillInBackground() async throws {
        let (folder, store, sample, queue) = try library()
        defer { store.database.close(); try? FileManager.default.removeItem(at: folder) }
        let formulas = ["Дней до срока", "Итог", "Проект (имя)"].map { sample.taskProperties[$0]! }
        try store.write { tx in
            for id in formulas { try tx.execute(sql: "DELETE FROM db_computed WHERE propertyId = ?", arguments: [.text(id.uuidString.lowercased())]) }
        }
        let gaps = MainThreadGaps()
        let ticker = Timer.scheduledTimer(withTimeInterval: 0.005, repeats: true) { _ in gaps.tick() }
        let started = ContinuousClock.now
        queue.fillMissing()
        await waitIdle(queue)
        let total = Self.seconds(ContinuousClock.now - started)
        ticker.invalidate()
        let filled = try store.write { tx in
            try tx.fetchTexts(sql: "SELECT CAST(COUNT(*) AS TEXT) FROM db_computed WHERE propertyId IN (?, ?, ?)",
                              arguments: formulas.map { .text($0.uuidString.lowercased()) }).first.flatMap(Int.init) ?? 0
        }
        let rows = try XCTUnwrap(try ViewQuery.open(sample.tableViewId, in: store)).result.rowIds.count
        let summary = "Первое заполнение: 3 формулы × \(rows) строк — \(String(format: "%.2f", total)) с в фоне (предел 5), записано \(filled) из \(rows * 3); главный поток замирал до \(ProbeEditor.format(gaps.longest)) мс"
        print(summary)
        add(XCTAttachment(string: summary))
        XCTAssertLessThanOrEqual(total, Self.firstFillBudgetSeconds)
        XCTAssertEqual(filled, rows * 3)
    }

    func testEditWithRecomputeAndOpenSortedByFormula() throws {
        let (folder, store, sample, _) = try library()
        defer { store.database.close(); try? FileManager.default.removeItem(at: folder) }
        let done = sample.taskProperties["Сделано"]!
        let rowIds = try XCTUnwrap(try ViewQuery.open(sample.tableViewId, in: store)).result.rowIds
        var edits: [Double] = []
        for index in 0..<40 {
            let row = rowIds[200 + index * 13]
            let ms = try ProbeEditor.measure {
                try store.write { tx in
                    let old = try tx.cell(rowId: row, propertyId: done)?.value?.bool ?? false
                    try tx.setCell(rowId: row, propertyId: done, value: .bool(!old))
                }
            }
            if index >= 5 { edits.append(ms) }
        }
        // Вид «работа» — фильтр И/ИЛИ и две сортировки, одна — по формуле (эталон R20).
        let opened = try XCTUnwrap(try ViewQuery.open(sample.workViewId, in: store))
        let sortsByFormula = (opened.view.sorts.array ?? []).contains { sort in
            sort["propertyId"]?.string.flatMap(UUID.init(uuidString:)).flatMap { opened.catalog.propertiesById[$0]?.kind } == .formula
        }
        var opens: [Double] = []
        for index in 0..<25 {
            let ms = try ProbeEditor.measure { _ = try ViewQuery.open(sample.workViewId, in: store) }
            if index >= 5 { opens.append(ms) }
        }
        let summary = """
            Правка флажка с пересчётом через подписчика записи: p95 \(ProbeEditor.format(ProbeEditor.p95(edits))) мс (предел 50)
            Открытие вида «работа» (сортировка по формуле: \(sortsByFormula ? "да" : "нет"), \(opened.result.rowIds.count) строк): p95 \(ProbeEditor.format(ProbeEditor.p95(opens))) мс (предел 50)
            """
        print(summary)
        add(XCTAttachment(string: summary))
        XCTAssertTrue(sortsByFormula)
        XCTAssertLessThanOrEqual(ProbeEditor.p95(edits), Self.editWaitBudgetMs)
        XCTAssertLessThanOrEqual(ProbeEditor.p95(opens), Self.openBudgetMs)
    }
}
