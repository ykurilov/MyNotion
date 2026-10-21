import Foundation
import Testing
@testable import DatabaseGrid
import Databases
import VisualStyle

/// Раскладка сетки (T083): строки разной высоты, группы со свёрнутыми, итоги, поиск строки под точкой.
@Suite("Раскладка сетки с группами (US3)")
struct GridLayoutTests {
    let row = Metrics.DatabaseGrid.rowHeight
    let header = Metrics.DatabaseGrid.headerHeight

    @Test("Без групп: строки подряд, «+ Новая строка» и итоги под ними")
    func plain() {
        let layout = GridLayout(rowCount: 3, rowHeight: { $0 == 1 ? 60 : 33 }, groups: nil, showsNewRow: true, hasTotals: true, showsNewGroup: false)
        #expect(layout.rowRect(1, width: 100).minY == header + row)
        #expect(layout.rowRect(2, width: 100).minY == header + row + 60)
        #expect(layout.rowsBottom == header + 2 * row + 60)
        #expect(layout.decorations.map(\.item) == [.newRow, .totals])
        #expect(layout.height == layout.rowsBottom + row + GridLayout.totalsHeight)
        #expect(layout.row(at: header + row + 59) == 1)
        #expect(layout.row(at: header + row + 61) == 2)
        #expect(layout.row(at: layout.rowsBottom + 1) == nil)
        #expect(layout.rows(from: header + row + 10, to: header + row + 70) == 1..<3)
        #expect(layout.insertionIndex(at: header + 30) == 1)
    }

    @Test("Группы: заголовок, строки, «+ Новая строка» и итоги у каждой; свёрнутая — только заголовок; «+ Новая группа» внизу")
    func grouped() {
        let groups = [
            GridGroupSection(key: "a", label: .text("А"), count: 2, rows: 0..<2, isCollapsed: false),
            GridGroupSection(key: "b", label: .text("Б"), count: 5, rows: 2..<2, isCollapsed: true),
            GridGroupSection(key: "c", label: .empty("Нет"), count: 1, rows: 2..<3, isCollapsed: false),
        ]
        let layout = GridLayout(rowCount: 3, rowHeight: { _ in 33 }, groups: groups, showsNewRow: true, hasTotals: true, showsNewGroup: true)
        #expect(layout.decorations.map(\.item) == [.groupHeader(0), .groupNewRow(0), .groupTotals(0), .groupHeader(1), .groupHeader(2),
                                                   .groupNewRow(2), .groupTotals(2), .newGroup])
        #expect(layout.rowRect(0, width: 10).minY == header + GridLayout.groupHeaderHeight)
        let third = layout.rowRect(2, width: 10).minY
        let headerC = layout.rect(of: .groupHeader(2), width: 10)!
        #expect(third == headerC.maxY)
        #expect(layout.row(at: headerC.midY) == nil)
        #expect(layout.decoration(at: headerC.midY)?.item == .groupHeader(2))
        #expect(layout.nearestRow(to: headerC.midY) == 2)
    }
}
