import AppKit
import DatabaseGrid
import Databases
import NotesCore
import XCTest

/// Проба сетки (T004, research R20.1): «Задачи» 10 000 строк × 30 свойств. Открытие до нарисованного первого экрана ≤ 50 мс;
/// прокрутка до конца и обратно — кадр p95 ≤ 16 мс, худший ≤ 50 мс; 5 снимков во время прокрутки — текст во всех видимых
/// строках; правка ячейки (буква, флажок) ≤ 50 мс. Кадр — сдвиг прокрутки, раскладка, рисование и передача слоёв.
@MainActor
final class DatabaseGridProbeTests: XCTestCase {
    static let openBudgetMs = 50.0
    static let frameBudgetMs = 16.0
    static let worstFrameBudgetMs = 50.0
    static let editBudgetMs = 50.0
    /// Сдвиг за кадр — быстрая прокрутка трекпадом.
    static let scrollStep: CGFloat = 240

    func testTasksGridOpensScrollsAndEditsWithinBudget() throws {
        let library = try DatabaseProbeLibrary.copy()
        defer { library.store.database.close(); try? FileManager.default.removeItem(at: library.folder) }
        let window = DatabaseProbeWindow()
        defer { window.close() }
        let sample = library.sample

        // Открытие: схема, запрос вида, первая порция строк, раскладка, рисование. Два прогрева, затем по 10 замеров.
        var opens: [String: [Double]] = [:], queries: [String: [Double]] = [:]
        var grid: DatabaseGridView!
        for (label, viewId) in [("Таблица", sample.tableViewId), ("Задачи — работа", sample.workViewId)] {
            for round in 0..<22 {
                var query = 0.0
                let ms = try ProbeEditor.measure {
                    query = try ProbeEditor.measure { _ = try ViewQuery.open(viewId, in: library.store) }
                    grid = try DatabaseProbeGrid.open(viewId: viewId, store: library.store)
                    window.show(grid)
                    window.render()
                }
                if round >= 2 { opens[label, default: []].append(ms - query); queries[label, default: []].append(query) }
                window.pump(30)
            }
        }
        // Дальше — «Таблица»: все 10 000 строк.
        grid = try DatabaseProbeGrid.open(viewId: sample.tableViewId, store: library.store)
        window.show(grid)
        window.render()
        window.pump(100)
        XCTAssertEqual(grid.content.rowCount, DatabaseSampleGenerator.taskCount)
        var shots: [String] = []
        let opened = try check(grid, label: "открытие", shots: &shots)

        // Прокрутка вниз до конца и обратно.
        var frames: [Double] = []
        var snapshotRows: [Int] = []
        var nextShot = 0
        let shotFractions: [CGFloat] = [0.1, 0.3, 0.5, 0.7, 0.9]
        let maxY = grid.scrollView.documentView!.frame.height - grid.scrollView.contentSize.height
        var inkProblems: [String] = []
        for direction in [1.0, -1.0] {
            var y = direction > 0 ? 0 : maxY
            while direction > 0 ? y < maxY : y > 0 {
                y = min(max(y + direction * Self.scrollStep, 0), maxY)
                let target = y
                frames.append(ProbeEditor.measure {
                    grid.scrollView.contentView.scroll(to: NSPoint(x: 0, y: target))
                    grid.scrollView.reflectScrolledClipView(grid.scrollView.contentView)
                    window.render()
                })
                if direction > 0, nextShot < shotFractions.count, y >= maxY * shotFractions[nextShot] {
                    let result = try check(grid, label: "прокрутка-\(Int(shotFractions[nextShot] * 100))", shots: &shots)
                    snapshotRows.append(result.rows)
                    inkProblems += result.problems
                    nextShot += 1
                }
                // Между кадрами — ход цикла событий: порции, прочитанные заранее, ложатся в сетку.
                RunLoop.current.run(until: Date().addingTimeInterval(0.001))
            }
        }

        // Правка: буква в «Описании» и флажок «Сделано» у видимой строки — запись, перечитывание строки, кадр.
        grid.scroll(toRow: 5_000)
        window.render()
        window.pump(100)
        let columns = grid.content.columns
        let textColumn = try XCTUnwrap(columns.firstIndex { $0.property.name == "Описание" })
        let checkColumn = try XCTUnwrap(columns.firstIndex { $0.property.name == "Сделано" })
        var letters: [Double] = [], checks: [Double] = []
        for step in 0..<20 {
            let index = 5_002 + step % 10
            let rowId = grid.content.rowIds[index]
            let textId = columns[textColumn].property.id, checkId = columns[checkColumn].property.id
            letters.append(try ProbeEditor.measure {
                try library.store.write { tx in
                    let old = try tx.cell(rowId: rowId, propertyId: textId)?.value?["string"]?.string ?? ""
                    try tx.setCell(rowId: rowId, propertyId: textId, value: try JSONValue(encoding: InlineText(old + "ы")))
                }
                grid.reloadRow(at: index)
                window.render()
            })
            checks.append(try ProbeEditor.measure {
                try library.store.write { tx in
                    let old = try tx.cell(rowId: rowId, propertyId: checkId)?.value?.bool ?? false
                    try tx.setCell(rowId: rowId, propertyId: checkId, value: .bool(!old))
                }
                grid.reloadRow(at: index)
                window.render()
            })
            window.pump(5)
        }
        let edited = try check(grid, label: "после-правки", shots: &shots)

        let sorted = frames.sorted()
        let summary = """
            Проба сетки: открытие «Таблица» p95 \(ProbeEditor.format(ProbeEditor.p95(opens["Таблица"]!))) мс, медиана \(ProbeEditor.format(ProbeEditor.median(opens["Таблица"]!))) мс; \
            «Задачи — работа» p95 \(ProbeEditor.format(ProbeEditor.p95(opens["Задачи — работа"]!))) мс (\(DatabaseSampleGenerator.taskCount) строк × \(columns.count) колонок, предел 50)
            Проба сетки: открытие по замерам «Таблица» — \(opens["Таблица"]!.map(ProbeEditor.format).joined(separator: " ")); \
            из них запрос вида p95 \(ProbeEditor.format(ProbeEditor.p95(queries["Таблица"]!))) / \(ProbeEditor.format(ProbeEditor.p95(queries["Задачи — работа"]!))) мс
            Проба сетки: прокрутка до конца и обратно — \(frames.count) кадров по \(Int(Self.scrollStep)) pt, p95 \(ProbeEditor.format(ProbeEditor.p95(frames))) мс, \
            медиана \(ProbeEditor.format(ProbeEditor.median(frames))) мс, худший \(ProbeEditor.format(sorted.last ?? 0)) мс (пределы 16 / 50); \
            порций прочитано на главном потоке \(grid.content.synchronousLoads)
            Проба сетки: снимки — открытие \(opened.rows) строк с текстом, прокрутка \(snapshotRows.map(String.init).joined(separator: " / ")), после правки \(edited.rows); \
            без текста: \(inkProblems.count + opened.problems.count + edited.problems.count)
            Проба сетки: правка буквы p95 \(ProbeEditor.format(ProbeEditor.p95(letters))) мс, флажка p95 \(ProbeEditor.format(ProbeEditor.p95(checks))) мс (предел 50)
            Снимок: \(shots.joined(separator: ", "))
            """
        print(summary)
        add(XCTAttachment(string: summary))

        XCTAssertLessThanOrEqual(ProbeEditor.p95(opens["Таблица"]!), Self.openBudgetMs, "Открытие «Таблица»: p95 больше 50 мс")
        XCTAssertLessThanOrEqual(ProbeEditor.p95(opens["Задачи — работа"]!), Self.openBudgetMs, "Открытие «Задачи — работа»: p95 больше 50 мс")
        XCTAssertLessThanOrEqual(ProbeEditor.p95(frames), Self.frameBudgetMs, "Прокрутка: кадр p95 больше 16 мс")
        XCTAssertLessThanOrEqual(sorted.last ?? 0, Self.worstFrameBudgetMs, "Прокрутка: худший кадр больше 50 мс")
        XCTAssertEqual(snapshotRows.count, 5, "Снято меньше 5 снимков прокрутки")
        XCTAssertTrue(inkProblems.isEmpty && opened.problems.isEmpty && edited.problems.isEmpty,
                      "Видимые строки без текста: \((opened.problems + inkProblems + edited.problems).prefix(5))")
        XCTAssertLessThanOrEqual(ProbeEditor.p95(letters), Self.editBudgetMs, "Правка буквы: p95 больше 50 мс")
        XCTAssertLessThanOrEqual(ProbeEditor.p95(checks), Self.editBudgetMs, "Правка флажка: p95 больше 50 мс")
    }

    /// Снимок сетки: в каждой целиком видимой строке у названия нарисован текст. Возвращает число таких строк и строки без текста.
    private func check(_ grid: DatabaseGridView, label: String, shots: inout [String]) throws -> (rows: Int, problems: [String]) {
        let bitmap = try XCTUnwrap(DatabaseProbeShots.snapshot(grid))
        shots.append(DatabaseProbeShots.save(bitmap, name: "db-grid-\(label)", to: self))
        var rows = 0
        var problems: [String] = []
        let headerBottom: CGFloat = 33
        for index in grid.visibleRows {
            let rect = grid.cellRect(row: index, column: 0)
            guard rect.minY >= headerBottom, rect.maxY <= grid.bounds.maxY - 16 else { continue }
            if DatabaseProbeShots.ink(in: bitmap, rect: rect, of: grid) > 0 { rows += 1 } else { problems.append("\(label): строка \(index)") }
        }
        return (rows, problems)
    }
}
