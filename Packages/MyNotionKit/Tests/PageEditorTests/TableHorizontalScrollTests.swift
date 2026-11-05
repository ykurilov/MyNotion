import AppKit
import Testing
@testable import NotesCore
@testable import PageEditor
import VisualStyle

/// Широкая простая таблица, как у Notion: начинается от левого края текста, занимает место справа до края страницы,
/// а дальше прокручивается вбок внутри себя; страница вбок не уезжает.
@MainActor
@Suite("Таблица шире колонки: прокрутка вбок")
struct TableHorizontalScrollTests {
    /// Таблица из «/» под абзацем «до»; ниже — абзацы, чтобы страница прокручивалась вниз.
    func tableFixture() throws -> (editor: EditorFixture, table: UUID) {
        let editor = try EditorFixture([.paragraph("до"), .paragraph()] + (0..<40).map { .paragraph("абзац \($0)") })
        editor.placeCaret(inBlock: 1)
        editor.type("/табл")
        editor.press(#selector(NSResponder.insertNewline(_:)))
        let table = try #require(editor.document.blocks.first { $0.kind == .table }).id
        editor.layoutViewport()
        return (editor, table)
    }

    func view(_ editor: EditorFixture, _ table: UUID) throws -> TableView {
        try #require(editor.textView.tableView(for: table))
    }

    func blockView(_ editor: EditorFixture, _ table: UUID) throws -> NSView {
        try #require(editor.textView.blockViews.view(for: table))
    }

    func scrollView(_ tableView: TableView) throws -> TableScrollView {
        try #require(tableView.enclosingScrollView as? TableScrollView)
    }

    /// Ещё `count` столбцов справа (новый — 120): сетка шире места до края страницы.
    func widen(_ editor: EditorFixture, _ table: UUID, by count: Int) throws {
        for _ in 0..<count {
            let tableView = try view(editor, table)
            let grid = try #require(editor.document.tableGrid(table))
            editor.step { tableView.perform(.insertColumnRight, at: TableCellPosition(row: 0, column: grid.columnCount - 1)) }
            editor.layoutViewport()
        }
    }

    func scrollEvent(dx: Int32, dy: Int32) throws -> NSEvent {
        let cgEvent = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0))
        return try #require(NSEvent(cgEvent: cgEvent))
    }

    func mouse(_ type: NSEvent.EventType, at windowPoint: NSPoint, in editor: EditorFixture) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: windowPoint, modifierFlags: [], timestamp: 0,
                                        windowNumber: editor.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    @Test("Таблица у края колонки: вид блока — по сетке с «+» столбца, «+» внутри вида и ловит щелчок, прокрутки нет")
    func fittingTable() throws {
        let (editor, table) = try tableFixture()
        let tableView = try view(editor, table)
        let host = try blockView(editor, table)
        let grid = tableView.tableLayout.gridSize
        #expect(host.frame.width == grid.width + Metrics.Table.addButtonGap + Metrics.Table.addButtonThickness)
        let scroll = try scrollView(tableView)
        #expect(scroll.frame == host.bounds)
        #expect(tableView.frame.width <= scroll.contentSize.width, "Прокручивать нечего")
        let local = NSPoint(x: grid.width + Metrics.Table.addButtonGap + Metrics.Table.addButtonThickness / 2, y: 10)
        #expect(host.bounds.contains(host.convert(local, from: tableView)), "«+» столбца — внутри вида блока")
        let page = try #require(editor.textView.superview)
        let hit = editor.textView.hitTest(page.convert(tableView.convert(local, to: nil), from: nil))
        #expect(hit?.accessibilityIdentifier() == "table-add-column", "Попал в \(String(describing: hit))")
    }

    @Test("Широкая таблица: вид блока — от левого края текста до края страницы, сетка прокручивается внутри, страница не шире окна")
    func wideTableScrollsInside() throws {
        let (editor, table) = try tableFixture()
        let left = try blockView(editor, table).frame.minX
        try widen(editor, table, by: 3)
        let tableView = try view(editor, table)
        let host = try blockView(editor, table)
        #expect(host.frame.minX == left, "Левый край — по тексту")
        #expect(host.frame.maxX == editor.textView.bounds.maxX, "Правый край — край страницы")
        let scroll = try scrollView(tableView)
        #expect(scroll.frame == host.bounds)
        #expect(scroll.documentView === tableView)
        #expect(tableView.frame.width == tableView.tableLayout.gridSize.width + Metrics.Table.addButtonGap + Metrics.Table.addButtonThickness)
        #expect(tableView.frame.width > scroll.contentSize.width, "Сетка шире видимой части")
        #expect(editor.textView.frame.width == 1200, "Страница не стала шире окна")
        #expect(scroll.hasHorizontalScroller && !scroll.hasVerticalScroller)
    }

    @Test("Колесо над таблицей: вбок остаётся прокрутке таблицы, вверх-вниз уходит странице")
    func wheelRouting() throws {
        let (editor, table) = try tableFixture()
        try widen(editor, table, by: 3)
        let scroll = try scrollView(try view(editor, table))
        let spy = WheelSpy()
        spy.nextResponder = scroll.nextResponder
        scroll.nextResponder = spy
        scroll.scrollWheel(with: try scrollEvent(dx: -5, dy: 0))
        #expect(spy.count == 0, "Колесо вбок ушло странице")
        scroll.scrollWheel(with: try scrollEvent(dx: 0, dy: -5))
        #expect(spy.count == 1, "Колесо вниз не ушло странице")
    }

    @Test("Прокрученная таблица: на линии последнего столбца — «↔», протяжка меняет его ширину")
    func resizeInScrolledPart() throws {
        let (editor, table) = try tableFixture()
        try widen(editor, table, by: 3)
        let tableView = try view(editor, table)
        let scroll = try scrollView(tableView)
        let maxX = tableView.frame.width - scroll.contentSize.width
        scroll.contentView.scroll(to: NSPoint(x: maxX, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        let layout = tableView.tableLayout
        let last = layout.columnWidths.count - 1
        let boundary = NSPoint(x: layout.columnX[last] + layout.columnWidths[last], y: layout.rowY[1] + 5)
        #expect(tableView.visibleRect.contains(boundary), "Граница последнего столбца видна после прокрутки")
        let windowPoint = tableView.convert(boundary, to: nil)
        #expect(tableView.pointer(atWindowPoint: windowPoint) == .resizeLeftRight)
        let page = try #require(editor.textView.superview)
        #expect(editor.textView.hitTest(page.convert(windowPoint, from: nil)) === tableView)
        let before = layout.columnWidths[last]
        tableView.mouseDown(with: try mouse(.leftMouseDown, at: windowPoint, in: editor))
        let moved = NSPoint(x: windowPoint.x + 40, y: windowPoint.y)
        tableView.mouseDragged(with: try mouse(.leftMouseDragged, at: moved, in: editor))
        editor.step { tableView.mouseUp(with: try! mouse(.leftMouseUp, at: moved, in: editor)) }
        #expect(try #require(editor.document.tableGrid(table)).columns[last].props.width == Double(before + 40))
        // Уже — шагами, как рукой: прокрученная к концу сетка не съезжает под мышью, столбец сужается ровно на сдвиг мыши.
        scroll.contentView.scroll(to: NSPoint(x: tableView.frame.width - scroll.contentSize.width, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        let start = tableView.convert(NSPoint(x: tableView.tableLayout.columnX[last] + tableView.tableLayout.columnWidths[last], y: boundary.y), to: nil)
        tableView.mouseDown(with: try mouse(.leftMouseDown, at: start, in: editor))
        for step in 1...5 {
            tableView.mouseDragged(with: try mouse(.leftMouseDragged, at: NSPoint(x: start.x - CGFloat(step) * 10, y: start.y), in: editor))
        }
        editor.step { tableView.mouseUp(with: try! mouse(.leftMouseUp, at: NSPoint(x: start.x - 50, y: start.y), in: editor)) }
        #expect(try #require(editor.document.tableGrid(table)).columns[last].props.width == Double(before - 10))
    }

    @Test("Tab в столбец за краем видимой части — таблица прокручивается к ячейке")
    func activatingHiddenCellScrollsToIt() throws {
        let (editor, table) = try tableFixture()
        try widen(editor, table, by: 3)
        let tableView = try view(editor, table)
        let scroll = try scrollView(tableView)
        let last = tableView.tableLayout.columnWidths.count - 1
        let cell = TableCellPosition(row: 0, column: last)
        #expect(!scroll.contentView.bounds.contains(tableView.tableLayout.cellRect(cell)), "Сначала ячейка за краем")
        tableView.activate(cell)
        #expect(scroll.contentView.bounds.contains(tableView.tableLayout.cellRect(cell)))
    }
}

/// Следующий ответчик прокрутки таблицы: считает колёса, ушедшие странице.
@MainActor
private final class WheelSpy: NSResponder {
    var count = 0
    override func scrollWheel(with event: NSEvent) { count += 1 }
}
