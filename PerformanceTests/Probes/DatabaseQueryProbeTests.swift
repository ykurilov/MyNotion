import AppKit
import DatabaseGrid
import Databases
import NotesCore
import XCTest

/// Проба запроса вида (T005, research R20.2): «Задачи — работа» — расширенный фильтр (статус не «Готово» И (срок на этой
/// неделе ИЛИ тег «Срочно»)), сортировка по формуле и по названию, группа по статусу — ≤ 30 мс; смена фильтра до
/// нарисованной сетки ≤ 100 мс; поиск ≤ 50 мс на символ; план SQLite — по индексам, без полного прохода `db_cell`.
@MainActor
final class DatabaseQueryProbeTests: XCTestCase {
    static let queryBudgetMs = 30.0
    static let filterChangeBudgetMs = 100.0
    static let searchBudgetMs = 50.0

    func testWorkViewQueryFilterChangeAndSearchWithinBudget() throws {
        let library = try DatabaseProbeLibrary.copy()
        defer { library.store.database.close(); try? FileManager.default.removeItem(at: library.folder) }
        let store = library.store, sample = library.sample
        let opened = try XCTUnwrap(try ViewQuery.open(sample.workViewId, in: store))
        let spec = ViewQuerySpec(view: opened.view)

        // Запрос вида: итог сверяется с фильтром «в лоб» по значениям ячеек.
        var queries: [Double] = []
        var result = opened.result
        for round in 0..<22 {
            let ms = try ProbeEditor.measure { result = try ViewQuery.rows(spec, catalog: opened.catalog, in: store) }
            if round >= 2 { queries.append(ms) }
        }
        let expected = try bruteForceWorkRows(store: store, sample: sample)
        XCTAssertEqual(Set(result.rowIds), expected, "Запрос вида и фильтр «в лоб» дали разные строки")
        let groups = Dictionary(grouping: result.groupKeys ?? [], by: { $0 }).mapValues(\.count)

        // План: только поиск по индексам.
        let plan = try ViewQuery.plan(spec, catalog: opened.catalog, in: store)
        let fullScans = plan.filter { $0.hasPrefix("SCAN") && ($0.contains("db_cell") || $0.contains("db_computed") || $0.contains(" s")) }

        // Смена фильтра до нарисованной сетки: без условия «Срочно», затем снова с ним.
        let window = DatabaseProbeWindow()
        defer { window.close() }
        let grid = try DatabaseProbeGrid.open(viewId: sample.workViewId, store: store)
        window.show(grid)
        window.render()
        var changes: [Double] = []
        guard case .and(let parts) = try XCTUnwrap(spec.filter), case .or(let either) = parts[1] else { return XCTFail("Не тот фильтр") }
        let narrower = FilterNode.and([parts[0], either[0]])
        for round in 0..<12 {
            var changed = spec
            changed.filter = round % 2 == 0 ? narrower : spec.filter
            let ms = try ProbeEditor.measure {
                let rows = try ViewQuery.rows(changed, catalog: opened.catalog, in: store)
                grid.content.replace(rowIds: rows.rowIds)
                grid.reloadData()
                window.render()
            }
            if round >= 2 { changes.append(ms) }
            window.pump(10)
        }

        // Поиск по символу: «з», «за», «зад»… по названию и видимым свойствам; каждый символ — новый запрос и кадр.
        var searchSpec = spec
        searchSpec.searchPropertyIds = ViewQuery.visiblePropertyIds(of: opened.view, catalog: opened.catalog)
        var searches: [Double] = []
        var lastCount = 0
        for round in 0..<3 {
            for length in 1...7 {
                searchSpec.search = String("отчёт б".prefix(length))
                let ms = try ProbeEditor.measure {
                    let rows = try ViewQuery.rows(searchSpec, catalog: opened.catalog, in: store)
                    lastCount = rows.rowIds.count
                    grid.content.replace(rowIds: rows.rowIds)
                    grid.reloadData()
                    window.render()
                }
                if round > 0 { searches.append(ms) }
            }
        }
        let searchPlan = try ViewQuery.plan(searchSpec, catalog: opened.catalog, in: store)
        let shot = try XCTUnwrap(DatabaseProbeShots.snapshot(grid))
        let path = DatabaseProbeShots.save(shot, name: "db-query-поиск", to: self)
        let ink = DatabaseProbeShots.ink(in: shot, rect: grid.cellRect(row: 0, column: 0), of: grid)

        let summary = """
            Проба запроса: «Задачи — работа» p95 \(ProbeEditor.format(ProbeEditor.p95(queries))) мс, медиана \(ProbeEditor.format(ProbeEditor.median(queries))) мс \
            (предел 30): \(result.rowIds.count) строк, групп \(groups.count), совпало с фильтром «в лоб»: \(Set(result.rowIds) == expected)
            Проба запроса: смена фильтра до экрана p95 \(ProbeEditor.format(ProbeEditor.p95(changes))) мс (предел 100); \
            поиск p95 \(ProbeEditor.format(ProbeEditor.p95(searches))) мс на символ (предел 50), на «отчёт б» строк \(lastCount)
            Проба запроса: план — \(plan.joined(separator: " | "))
            Проба запроса: план поиска — \(searchPlan.joined(separator: " | "))
            Снимок: \(path) (нарисовано у первой строки \(String(format: "%.0f", ink * 100)) %)
            """
        print(summary)
        add(XCTAttachment(string: summary))
        XCTAssertLessThanOrEqual(ProbeEditor.p95(queries), Self.queryBudgetMs, "Запрос вида: p95 больше 30 мс")
        XCTAssertLessThanOrEqual(ProbeEditor.p95(changes), Self.filterChangeBudgetMs, "Смена фильтра: p95 больше 100 мс")
        XCTAssertLessThanOrEqual(ProbeEditor.p95(searches), Self.searchBudgetMs, "Поиск: p95 больше 50 мс на символ")
        XCTAssertTrue(fullScans.isEmpty, "Полный проход: \(fullScans)")
        XCTAssertTrue(searchPlan.filter { $0.hasPrefix("SCAN") && $0.contains("db_") }.isEmpty, "Поиск: полный проход")
        XCTAssertGreaterThan(ink, 0, "После поиска первая строка не нарисована")
    }

    /// Строки вида «работа» по значениям ячеек, без запроса вида.
    private func bruteForceWorkRows(store: NotesStore, sample: DatabaseSampleGenerator.Sample) throws -> Set<UUID> {
        let status = sample.taskProperties["Статус"]!, deadline = sample.taskProperties["Срок"]!, tags = sample.taskProperties["Теги"]!
        let done = sample.options[status]!["Готово"]!, urgent = sample.options[tags]!["Срочно"]!
        let week = try XCTUnwrap(Calendar.current.dateInterval(of: .weekOfYear, for: Date()))
        var rows: Set<UUID> = []
        try store.write { tx in
            for raw in try tx.fetchTexts(sql: "SELECT id FROM page WHERE parentId = ? AND trashedAt IS NULL",
                                         arguments: [.text(sample.tasksId.uuidString.lowercased())]) {
                let row = UUID(uuidString: raw)!
                let isDone = try tx.cell(rowId: row, propertyId: status)?.value?.string == done.uuidString.lowercased()
                let date = try tx.cell(rowId: row, propertyId: deadline)?.value?["start"]?.string.flatMap { DateText.parse($0, timeZone: nil) }
                let inWeek = date.map { $0 >= week.start && $0 < week.end } ?? false
                let isUrgent = try tx.cell(rowId: row, propertyId: tags)?.value?.array?.contains(.string(urgent.uuidString.lowercased())) ?? false
                if !isDone, inWeek || isUrgent { rows.insert(row) }
            }
        }
        return rows
    }
}
