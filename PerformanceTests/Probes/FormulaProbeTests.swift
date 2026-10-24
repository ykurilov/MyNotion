import AppKit
import DatabaseGrid
import Databases
import NotesCore
import XCTest

/// Проба формул (T006, research R20.3, решение R21): 3 формулы «Задач» — `dateBetween` со сроком, `if` по флажку, `map`
/// по связи — пересчитываются на 10 000 строках в фоне (`FormulaRecompute.recomputeAll`: чтение и вычисление вне записи,
/// итоги короткими пачками). Пока идёт пересчёт, главный поток каждые 30 мс правит флажок «Сделано» с пересчётом своей
/// строки — правка ждёт очередь записи ≤ 50 мс p95. Итог всех строк сходится с подсчётом «в лоб» (и у поправленных);
/// одна правка с пересчётом строки — ≤ 5 мс; снимок сетки — итоги нарисованы.
@MainActor
final class FormulaProbeTests: XCTestCase {
    static let editWaitBudgetMs = 50.0
    static let editBudgetMs = 5.0

    func testBackgroundRecomputeKeepsEditsResponsive() async throws {
        let library = try DatabaseProbeLibrary.copy()
        defer { library.store.database.close(); try? FileManager.default.removeItem(at: library.folder) }
        let store = library.store, sample = library.sample
        let names = ["Дней до срока", "Итог", "Проект (имя)"]
        let formulaIds = Set(names.map { sample.taskProperties[$0]! })
        let done = sample.taskProperties["Сделано"]!
        // Итоги генератора стираются: пересчёт пишет их заново.
        try store.write { tx in
            for id in formulaIds { try tx.execute(sql: "DELETE FROM db_computed WHERE propertyId = ?", arguments: [.text(id.uuidString.lowercased())]) }
        }
        let now = Date()
        let recompute = try FormulaRecompute(store: store, databaseId: sample.tasksId, propertyIds: formulaIds, now: { now })
        XCTAssertEqual(recompute.formulas.count, 3)
        let rowIds = try XCTUnwrap(try ViewQuery.open(sample.tableViewId, in: store)).result.rowIds

        // Главный поток: отметки каждые 5 мс и правка флажка с пересчётом строки каждые 30 мс.
        let gaps = MainThreadGaps()
        let ticker = Timer.scheduledTimer(withTimeInterval: 0.005, repeats: true) { _ in gaps.tick() }
        var waits: [Double] = []
        var editedRows: [UUID] = []
        var step = 0
        let editor = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { _ in
            MainActor.assumeIsolated {
                step += 1
                let row = rowIds[(step * 37) % rowIds.count]
                editedRows.append(row)
                waits.append((try? ProbeEditor.measure {
                    try store.write { tx in
                        let old = try tx.cell(rowId: row, propertyId: done)?.value?.bool ?? false
                        try tx.setCell(rowId: row, propertyId: done, value: .bool(!old))
                        try recompute.recompute(rows: [row], in: tx)
                    }
                }) ?? -1)
            }
        }
        let started = ContinuousClock.now
        let task = Task.detached(priority: .userInitiated) { try recompute.recomputeAll(readBatch: 500, writeBatch: 50) }
        let report = try await task.value
        let total = ContinuousClock.now - started
        editor.invalidate()
        ticker.invalidate()
        let seconds = Double(total.components.seconds) + Double(total.components.attoseconds) / 1e18

        // Все строки — как подсчёт «в лоб» по ячейкам и связям (у поправленных — по новому флажку).
        var mismatches: [String] = []
        let deadline = sample.taskProperties["Срок"]!, project = sample.taskProperties["Проект"]!
        try store.write { tx in
            for row in rowIds {
                let isDone = try tx.cell(rowId: row, propertyId: done)?.value?.bool ?? false
                let start = try tx.cell(rowId: row, propertyId: deadline)?.value?["start"]?.string.flatMap { DateText.parse($0, timeZone: nil) }
                let title = try tx.relationLinks(propertyId: project, rowId: row).first.flatMap { try tx.page($0.targetRowId)?.title }
                let expected: [String: String] = [
                    "Итог": JSONValue.string(isDone ? "Готово" : "В работе").jsonText,
                    "Дней до срока": JSONValue.number(Double(Calendar.current.dateComponents([.day], from: now, to: start!).day!)).jsonText,
                    "Проект (имя)": JSONValue.array([.string(title!)]).jsonText,
                ]
                for name in names {
                    let stored = try tx.fetchTexts(sql: "SELECT value FROM db_computed WHERE rowId = ? AND propertyId = ?",
                                                   arguments: [.text(row.uuidString.lowercased()), .text(sample.taskProperties[name]!.uuidString.lowercased())]).first
                    if stored != expected[name] { mismatches.append("\(name) \(row): \(stored ?? "нет") ≠ \(expected[name]!)") }
                }
            }
        }

        // Одна правка с пересчётом строки.
        var edits: [Double] = []
        for index in 0..<25 {
            let row = rowIds[100 + index]
            let ms = try ProbeEditor.measure {
                try store.write { tx in
                    let old = try tx.cell(rowId: row, propertyId: done)?.value?.bool ?? false
                    try tx.setCell(rowId: row, propertyId: done, value: .bool(!old))
                    try recompute.recompute(rows: [row], in: tx)
                }
            }
            if index >= 5 { edits.append(ms) }
        }

        // Снимок: колонки формул в сетке нарисованы.
        let window = DatabaseProbeWindow()
        defer { window.close() }
        let grid = try DatabaseProbeGrid.open(viewId: sample.tableViewId, store: store)
        window.show(grid)
        let firstFormula = try XCTUnwrap(grid.content.columns.firstIndex { $0.property.name == "Дней до срока" })
        let x = grid.content.columns.prefix(firstFormula).reduce(0) { $0 + $1.width } - 100
        grid.scrollView.contentView.scroll(to: NSPoint(x: x, y: 0))
        grid.scrollView.reflectScrolledClipView(grid.scrollView.contentView)
        window.render()
        window.pump(200)
        let bitmap = try XCTUnwrap(DatabaseProbeShots.snapshot(grid))
        let shot = DatabaseProbeShots.save(bitmap, name: "db-formulas-итоги", to: self)
        var drawn = 0, checked = 0
        for row in grid.visibleRows {
            for column in firstFormula..<firstFormula + 3 {
                let rect = grid.cellRect(row: row, column: column)
                guard rect.minY >= 33, rect.maxY <= grid.bounds.maxY - 16, rect.maxX <= grid.bounds.maxX else { continue }
                checked += 1
                if DatabaseProbeShots.ink(in: bitmap, rect: rect, of: grid) > 0 { drawn += 1 }
            }
        }

        let summary = """
            Проба формул: 3 формулы × \(rowIds.count) строк в фоне — \(String(format: "%.2f", seconds)) с, записано \(report.written) итогов \
            пачками по 50 строк (\(report.writeBatches) записей, самая долгая \(ProbeEditor.format(report.longestWriteMs)) мс), пересчитано заново поправленных строк \(report.retried)
            Проба формул: правка флажка с главного потока во время пересчёта ждёт p95 \(ProbeEditor.format(ProbeEditor.p95(waits))) мс, \
            медиана \(ProbeEditor.format(ProbeEditor.median(waits))) мс, худшая \(ProbeEditor.format(waits.max() ?? 0)) мс (\(waits.count) правок, предел 50); \
            главный поток замирал до \(ProbeEditor.format(gaps.longest)) мс
            Проба формул: итог сошёлся с подсчётом «в лоб» у \(rowIds.count * 3 - mismatches.count) из \(rowIds.count * 3) (поправлено строк \(Set(editedRows).count)); \
            правка с пересчётом строки p95 \(ProbeEditor.format(ProbeEditor.p95(edits))) мс (предел 5)
            Проба формул: снимок — итоги нарисованы в \(drawn) из \(checked) видимых ячеек формул
            Снимок: \(shot)
            """
        print(summary)
        add(XCTAttachment(string: summary + "\n" + mismatches.prefix(5).joined(separator: "\n")))
        XCTAssertLessThanOrEqual(ProbeEditor.p95(waits), Self.editWaitBudgetMs, "Правка во время пересчёта ждёт больше 50 мс (p95)")
        XCTAssertGreaterThan(waits.count, 5, "Пересчёт закончился раньше, чем главный поток успел править")
        XCTAssertTrue(mismatches.isEmpty, "Итог не сходится: \(mismatches.prefix(3))")
        XCTAssertLessThanOrEqual(ProbeEditor.p95(edits), Self.editBudgetMs, "Правка с пересчётом строки: p95 больше 5 мс")
        XCTAssertTrue(checked > 0 && drawn == checked, "Итоги формул нарисованы не во всех видимых ячейках")
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
