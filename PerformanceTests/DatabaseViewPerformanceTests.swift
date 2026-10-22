import AppKit
import DatabaseGrid
import DatabaseViewBar
import Databases
import NotesCore
import XCTest

/// Замеры вида US3 (T085) на эталоне баз: «Задачи» — 10 000 строк, окно 1440×900. Смена фильтра, сортировки, группировки
/// и видимости — от правки до нарисованной таблицы p95 ≤ 100 мс; поиск — на каждый символ p95 ≤ 50 мс; прокрутка вида с
/// группами, итогами и переносом текста — кадр p95 ≤ 16 мс; открытие «Задачи — работа» p95 ≤ 50 мс.
@MainActor
final class DatabaseViewPerformanceTests: XCTestCase {
    static let changeBudgetMs = 100.0
    static let searchBudgetMs = 50.0
    static let frameBudgetMs = 16.0

    func testViewChangesSearchAndGroupedScrollWithinBudget() throws {
        let library = try DatabaseProbeLibrary.copy()
        defer { library.store.database.close(); try? FileManager.default.removeItem(at: library.folder) }
        let store = library.store, sample = library.sample
        store.addWriteHook(CellIndexer())
        let operations = DatabaseOperations(store: store)
        let window = DatabaseProbeWindow()
        defer { window.close() }
        let property = { (name: String) in sample.taskProperties[name]! }

        let controller = try XCTUnwrap(DatabaseTableController(store: store, operations: operations, databaseId: sample.tasksId,
                                                               viewId: sample.tableViewId))
        let table = DatabaseTableView(controller: controller, mode: .page)
        window.show(table)
        window.render()
        window.pump(200)
        let viewId = sample.tableViewId
        let doneId = try XCTUnwrap(sample.options[property("Статус")]?["Готово"])

        /// Правка вида до нарисованной таблицы: операция, перечитывание вида, раскладка и кадр.
        var parts: [String: [Double]] = [:]
        func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
        func lap(_ name: String, _ start: inout UInt64) {
            let end = now()
            parts[name, default: []].append(Double(end - start) / 1_000_000)
            start = end
        }
        func change(_ body: () throws -> Void) throws -> Double {
            let first = now()
            var start = first
            try body()
            lap("операция и перечитывание", &start)
            _ = try ViewQuery.present(viewId, in: store)
            lap("запрос", &start)
            // Таблица уже перечитана: операция сообщает о правке (`DatabaseOperations.didChange`), контроллер ловит её сразу.
            window.window.contentView?.layoutSubtreeIfNeeded()
            lap("раскладка", &start)
            window.window.displayIfNeeded()
            lap("рисование", &start)
            CATransaction.flush()
            lap("передача", &start)
            // Проверочный запрос — не часть правки.
            return Double(start - first) / 1_000_000 - (parts["запрос"]?.last ?? 0)
        }
        let notDone = FilterNode.condition(FilterCondition(propertyId: property("Статус"), op: .isNot, value: [.string(doneId.uuidString.lowercased())]))
        var filters: [Double] = [], sorts: [Double] = [], groups: [Double] = [], visibility: [Double] = []
        for round in 0..<12 {
            let on = round % 2 == 0
            filters.append(try change { try operations.setFilter(on ? notDone : nil, of: viewId) })
            // Правка дошла до таблицы сразу (а не на следующем такте): иначе замер был бы занижен.
            XCTAssertEqual(controller.content.rowIds.count < DatabaseSampleGenerator.taskCount, on, "Фильтр не перечитал таблицу сразу")
            sorts.append(try change {
                try operations.setSorts(on ? [SortSpec(propertyId: property("Срок")), SortSpec(propertyId: property("Название"))] : [], of: viewId)
            })
            groups.append(try change { try operations.setGroup(on ? GroupSettings(propertyId: property("Статус")) : nil, of: viewId) })
            visibility.append(try change { try operations.setVisible(property("Описание"), !on, in: viewId) })
            window.pump(20)
        }
        // Первые два круга — прогрев.
        let warm = { (values: [Double]) in Array(values.dropFirst(2)) }

        // Поиск: «отчёт» по символу, затем стирание.
        try operations.setFilter(nil, of: viewId)
        controller.reload()
        var searches: [Double] = []
        let word = Array("отчёт")
        for round in 0..<4 {
            // Лупа: поле открылось — текст строк для поиска читается заранее.
            controller.prepareSearch()
            for length in 1...word.count {
                var start = now()
                _ = try ViewQuery.present(viewId, in: store, search: String(word.prefix(length)))
                lap("поиск: запрос", &start)
                let first = start
                controller.setSearch(String(word.prefix(length)))
                lap("поиск: перечитать", &start)
                window.render()
                lap("поиск: кадр", &start)
                searches.append(Double(start - first) / 1_000_000)
            }
            controller.setSearch(nil)
            window.render()
            if round == 0 { searches.removeAll() }
        }

        // Открытие «Задачи — работа»: фильтр, две сортировки, группы по статусу.
        var opens: [Double] = []
        for round in 0..<12 {
            window.pump(20)
            let ms = try ProbeEditor.measure {
                let work = try XCTUnwrap(DatabaseTableController(store: store, operations: operations, databaseId: sample.tasksId,
                                                                 viewId: sample.workViewId))
                window.show(DatabaseTableView(controller: work, mode: .page))
                window.render()
            }
            if round >= 2 { opens.append(ms) }
        }

        // Прокрутка вида с группами, итогами и переносом: сетка со своей прокруткой во всё окно.
        try operations.setWrap(property("Описание"), true, in: sample.workViewId)
        try operations.setCalculation(.sum, of: property("Часы"), in: sample.workViewId)
        try operations.setGroup(GroupSettings(propertyId: property("Приоритет")), of: sample.workViewId)
        try operations.setFilter(nil, of: sample.workViewId)
        let grouped = try XCTUnwrap(DatabaseTableController(store: store, operations: operations, databaseId: sample.tasksId,
                                                           viewId: sample.workViewId))
        let grid = DatabaseGridView(controller: grouped, scrollsVertically: true)
        grid.groupSections = grouped.sections
        window.show(grid)
        window.render()
        window.pump(300)
        XCTAssertGreaterThan(grouped.sections?.count ?? 0, 2, "Групп по приоритету нет")
        var frames: [Double] = []
        let step: CGFloat = 240
        var y: CGFloat = 0
        for _ in 0..<400 {
            let maxY = grid.scrollView.documentView!.frame.height - grid.scrollView.contentSize.height
            guard y < maxY else { break }
            y = min(y + step, maxY)
            let target = y
            frames.append(ProbeEditor.measure {
                grid.scrollView.contentView.scroll(to: NSPoint(x: 0, y: target))
                grid.scrollView.reflectScrolledClipView(grid.scrollView.contentView)
                window.render()
            })
            RunLoop.current.run(until: Date().addingTimeInterval(0.001))
        }
        let shot = try XCTUnwrap(DatabaseProbeShots.snapshot(window.window.contentView!))
        let shotPath = DatabaseProbeShots.save(shot, name: "us3-группы-перенос", to: self)

        let p95 = { (values: [Double]) in ProbeEditor.format(ProbeEditor.p95(values)) }
        let summary = """
            Вид US3: фильтр p95 \(p95(warm(filters))) мс, сортировка \(p95(warm(sorts))) мс, группировка \(p95(warm(groups))) мс, \
            видимость \(p95(warm(visibility))) мс (предел 100); поиск на символ p95 \(p95(searches)) мс (предел 50); \
            открытие «Задачи — работа» p95 \(p95(opens)) мс; прокрутка с группами и переносом — \(frames.count) кадров, \
            p95 \(p95(frames)) мс (предел 16), худший \(ProbeEditor.format(frames.max() ?? 0)) мс (предел 50), снимок \(shotPath); части (медиана): \
            \(parts.sorted { $0.key < $1.key }.map { "\($0.key) \(ProbeEditor.format(ProbeEditor.median($0.value)))" }.joined(separator: ", "))
            """
        print(summary)
        XCTContext.runActivity(named: summary) { _ in }
        XCTAssertLessThanOrEqual(ProbeEditor.p95(warm(filters)), Self.changeBudgetMs, "Смена фильтра дольше 100 мс. \(summary)")
        XCTAssertLessThanOrEqual(ProbeEditor.p95(warm(sorts)), Self.changeBudgetMs, "Смена сортировки дольше 100 мс")
        XCTAssertLessThanOrEqual(ProbeEditor.p95(warm(groups)), Self.changeBudgetMs, "Смена группировки дольше 100 мс")
        XCTAssertLessThanOrEqual(ProbeEditor.p95(warm(visibility)), Self.changeBudgetMs, "Смена видимости дольше 100 мс")
        XCTAssertLessThanOrEqual(ProbeEditor.p95(searches), Self.searchBudgetMs, "Поиск: символ дольше 50 мс")
        XCTAssertLessThanOrEqual(ProbeEditor.p95(opens), 50, "Открытие «Задачи — работа» дольше 50 мс")
        XCTAssertLessThanOrEqual(frames.max() ?? 0, 50, "Прокрутка с группами: худший кадр больше 50 мс")
        XCTAssertLessThanOrEqual(ProbeEditor.p95(frames), Self.frameBudgetMs, "Прокрутка с группами: кадр p95 больше 16 мс")
    }
}
