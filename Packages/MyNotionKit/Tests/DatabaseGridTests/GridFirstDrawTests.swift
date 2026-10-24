import AppKit
import Foundation
import Testing
@testable import DatabaseGrid
@testable import Databases
@testable import NotesCore
import VisualStyle

/// Первая отрисовка таблицы (T085): на главном потоке читаются только строки первого экрана, порция целиком — фоном.
@MainActor
@Suite("Сетка: первая отрисовка")
struct GridFirstDrawTests {
    @Test("Открыли таблицу в 300 строк — до первой картинки прочитан только первый экран, строки нарисованы")
    func firstDrawReadsVisibleRowsOnly() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("first-draw-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = NotesStore(database: try AppDatabase.open(at: folder.appendingPathComponent("MyNotion.sqlite")), clock: HybridLogicalClock(deviceId: UUID()))
        let operations = DatabaseOperations(store: store)
        let base = try operations.createDatabase(in: nil, isInline: false, title: "Задачи")
        for index in 0..<300 { try operations.addRow(to: base.databaseId, in: base.viewId, title: "Строка \(index)") }
        let controller = try #require(DatabaseTableController(store: store, operations: operations, databaseId: base.databaseId))
        let grid = DatabaseGridView(controller: controller, scrollsVertically: true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = grid
        grid.layoutSubtreeIfNeeded()
        // Отрисовка без показа окна на экране: та же `draw`, что и в первом кадре.
        let bitmap = try #require(grid.bitmapImageRepForCachingDisplay(in: grid.bounds))
        grid.cacheDisplay(in: grid.bounds, to: bitmap)

        let screen = Int((600 / Metrics.DatabaseGrid.rowHeight).rounded(.up)) + 1
        #expect(grid.content.rowsReadOnMainThread <= screen, "прочитано \(grid.content.rowsReadOnMainThread), экран — \(screen)")
        #expect(grid.content.rowsReadOnMainThread > 0, "первый экран нарисован из прочитанных строк")
        #expect(grid.content.row(at: 0)?.cells.isEmpty == false)
    }
}
