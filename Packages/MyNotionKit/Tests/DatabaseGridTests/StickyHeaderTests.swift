import AppKit
import Foundation
import Testing
@testable import DatabaseGrid
@testable import Databases
@testable import NotesCore
import VisualStyle

/// Страница-база в прокрутке страницы (Notion 7.39): название уезжает вверх, шапка колонок держится у верха видимой
/// части, пока видны строки таблицы.
@MainActor
@Suite("Сетка: липкая шапка")
struct StickyHeaderTests {
    @Test("Страницу пролистали ниже верха таблицы — шапка у верха видимой части; вернули — на своём месте")
    func headerSticksToTop() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sticky-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = NotesStore(database: try AppDatabase.open(at: folder.appendingPathComponent("MyNotion.sqlite")), clock: HybridLogicalClock(deviceId: UUID()))
        let operations = DatabaseOperations(store: store)
        let base = try operations.createDatabase(in: nil, isInline: false, title: "Задачи")
        for index in 0..<200 { try operations.addRow(to: base.databaseId, in: base.viewId, title: "Строка \(index)") }
        let controller = try #require(DatabaseTableController(store: store, operations: operations, databaseId: base.databaseId))
        let grid = DatabaseGridView(controller: controller, scrollsVertically: false)

        // Страница: 300 pt над таблицей (название), дальше таблица во всю высоту строк.
        let page = FlippedView(frame: NSRect(x: 0, y: 0, width: 900, height: 300 + grid.fittingHeight))
        grid.frame = NSRect(x: 0, y: 300, width: 900, height: grid.fittingHeight)
        page.addSubview(grid)
        let outer = NSScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        outer.documentView = page
        let window = NSWindow(contentRect: outer.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = outer
        grid.layoutSubtreeIfNeeded()

        func scroll(to y: CGFloat) {
            outer.contentView.scroll(to: NSPoint(x: 0, y: y))
            outer.reflectScrolledClipView(outer.contentView)
            grid.updateStickyHeader()
        }
        scroll(to: 0)
        #expect(grid.headerView.frame.minY == 0)
        scroll(to: 1_000)
        #expect(grid.headerView.frame.minY == 700, "верх видимой части — 1 000 pt страницы, таблица начинается с 300")
        scroll(to: 100)
        #expect(grid.headerView.frame.minY == 0, "таблица видна сверху — шапка на месте")
        scroll(to: 300 + grid.fittingHeight + 50)
        #expect(grid.headerView.frame.minY <= grid.fittingHeight - Metrics.DatabaseGrid.headerHeight, "шапка не уходит ниже таблицы")
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
