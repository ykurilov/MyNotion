import AppKit
import DatabaseGrid
import Databases
import NotesCore
import PageEditor
import XCTest

/// Проба встроенной базы (T008, research R20.5): «Обзор» — 200 блоков текста и встроенная «Задачи (встроенная)» на 10 000
/// строк. Переход на «Обзор» ≤ 50 мс, набор рядом с базой p95 ≤ 50 мс, снимок — сетка нарисована, строк — по пределу
/// загрузки 50. Вид блока `database` даёт фабрика видов редактора (как в приложении: редактор знает только протокол).
@MainActor
final class InlineDatabaseProbeTests: XCTestCase {
    static let budgetMs = 50.0

    func testOverviewWithInlineDatabaseOpensAndTypesWithinBudget() async throws {
        let library = try DatabaseProbeLibrary.copy()
        defer { library.store.database.close(); try? FileManager.default.removeItem(at: library.folder) }
        let store = library.store, sample = library.sample
        let factory = InlineDatabaseProbeFactory(store: store)
        BlockViewFactories.shared.register(factory, for: .database)
        defer { BlockViewFactories.shared.unregister(.database) }

        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: window.contentLayoutRect)
        scroll.hasVerticalScroller = true
        scroll.autoresizingMask = [.width, .height]
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        func pump(_ milliseconds: Int) {
            autoreleasepool {
                RunLoop.current.run(until: Date().addingTimeInterval(Double(milliseconds) / 1_000))
                window.displayIfNeeded()
            }
        }
        func show(_ pageId: UUID) throws -> PageTextView {
            let editor = PageTextView(document: PageDocument(content: try XCTUnwrap(try store.pageContent(pageId))), initialFocus: .unchanged)
            scroll.documentView = editor
            editor.frame.size.width = scroll.contentSize.width
            window.makeFirstResponder(editor)
            return editor
        }
        // Обычная страница для перехода туда и обратно: строка «Проектов» (страница с одним абзацем).
        let plain = try XCTUnwrap(try store.write { tx in
            try tx.fetchTexts(sql: "SELECT id FROM page WHERE parentId = ? LIMIT 1", arguments: [.text(sample.projectsId.uuidString.lowercased())]).first
        }.flatMap(UUID.init(uuidString:)))

        // Переход на «Обзор»: редактор, раскладка, первый экран. Верх страницы — блоки текста, база ниже экрана; затем —
        // переход с прокруткой к базе (сетка в первом экране).
        var opens: [Double] = [], opensAtGrid: [Double] = []
        var editor: PageTextView!
        for round in 0..<12 {
            _ = try show(plain)
            window.displayIfNeeded()
            pump(10)
            let ms = try ProbeEditor.measure {
                editor = try show(sample.overviewId)
                window.displayIfNeeded()
            }
            pump(10)
            let atGrid = try ProbeEditor.measure {
                editor = try show(sample.overviewId)
                editor.scrollRangeToVisible(NSRange(location: Self.location(ofBlock: 101, in: editor), length: 0))
                window.displayIfNeeded()
            }
            if round >= 2 { opens.append(ms); opensAtGrid.append(atGrid) }
            pump(10)
        }

        // Снимок: сетка встроенной базы на экране, строк — по пределу загрузки.
        editor.scrollRangeToVisible(NSRange(location: Self.location(ofBlock: 101, in: editor), length: 0))
        pump(300)
        let grid = try XCTUnwrap(Self.find(DatabaseGridView.self, in: editor), "Сетка встроенной базы не показана")
        let frameView = try XCTUnwrap(window.contentView?.superview)
        let bitmap = try XCTUnwrap(frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds))
        frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
        let shot = DatabaseProbeShots.save(bitmap, name: "db-inline-обзор", to: self)
        let gridShot = try XCTUnwrap(DatabaseProbeShots.snapshot(grid))
        DatabaseProbeShots.save(gridShot, name: "db-inline-сетка", to: self)
        let visible = grid.visibleRect
        var drawnRows = 0
        for index in 0..<grid.content.rowCount {
            let rect = grid.cellRect(row: index, column: 0)
            guard visible.contains(rect) else { continue }
            if DatabaseProbeShots.ink(in: gridShot, rect: rect, of: grid) > 0 { drawnRows += 1 }
        }

        // Набор в абзаце над базой: букву за буквой, с перерисовкой окна.
        let caret = Self.location(ofBlock: 99, in: editor)
        let paragraph = (editor.string as NSString).paragraphRange(for: NSRange(location: caret, length: 0))
        editor.setSelectedRange(NSRange(location: NSMaxRange(paragraph) - 1, length: 0))
        pump(100)
        var typing: [Double] = []
        let characters = Array("быстрый набор рядом с базой ")
        for index in 0..<60 {
            let character = String(characters[index % characters.count])
            let ms = ProbeEditor.measure {
                editor.insertText(character, replacementRange: NSRange(location: NSNotFound, length: 0))
                window.displayIfNeeded()
            }
            if index >= 5 { typing.append(ms) }
            pump(8)
        }

        let summary = """
            Проба встроенной базы: переход на «Обзор» p95 \(ProbeEditor.format(ProbeEditor.p95(opens))) мс, с прокруткой к базе \
            p95 \(ProbeEditor.format(ProbeEditor.p95(opensAtGrid))) мс (предел 50); строк в сетке \(grid.content.rowCount) из \(grid.content.rowIds.count), \
            нарисовано целиком видимых \(drawnRows); набор рядом с базой p95 \(ProbeEditor.format(ProbeEditor.p95(typing))) мс (предел 50)
            Снимок: \(shot)
            """
        print(summary)
        add(XCTAttachment(string: summary))
        XCTAssertLessThanOrEqual(ProbeEditor.p95(opens), Self.budgetMs, "Переход на «Обзор»: p95 больше 50 мс")
        XCTAssertLessThanOrEqual(ProbeEditor.p95(opensAtGrid), Self.budgetMs, "Переход на «Обзор» к базе: p95 больше 50 мс")
        XCTAssertEqual(grid.content.rowCount, 50, "Встроенная база показывает не по пределу загрузки")
        XCTAssertGreaterThan(drawnRows, 5, "Строки встроенной базы не нарисованы")
        XCTAssertLessThanOrEqual(ProbeEditor.p95(typing), Self.budgetMs, "Набор рядом с базой: p95 больше 50 мс")
    }

    static func location(ofBlock index: Int, in editor: PageTextView) -> Int {
        let string = editor.string as NSString
        var location = 0
        for _ in 0..<index { location = NSMaxRange(string.paragraphRange(for: NSRange(location: location, length: 0))) }
        return min(location, string.length)
    }

    static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews { if let match = find(type, in: subview) { return match } }
        return nil
    }
}

/// Вид блока встроенной базы для пробы: сетка первого вида базы по пределу загрузки (`layoutOptions.loadLimit`).
@MainActor
final class InlineDatabaseProbeFactory: BlockViewFactory {
    let store: NotesStore
    private var heights: [UUID: CGFloat] = [:]

    init(store: NotesStore) { self.store = store }

    func makeView(for block: Block, context: BlockViewContext) -> NSView? {
        guard let databaseId = block.linkedPageId, let viewId = try? ViewQuery.firstViewId(of: databaseId, in: store),
              let opened = try? ViewQuery.open(viewId, in: store) else { return nil }
        let limit = Int(opened.view.layoutOptions["loadLimit"]?.number ?? 50)
        let content = GridContent(store: store, catalog: opened.catalog, columns: DatabaseProbeGrid.columns(of: opened.view, catalog: opened.catalog),
                                  rowIds: opened.result.rowIds, loadLimit: limit)
        let grid = DatabaseGridView(content: content, scrollsVertically: false)
        heights[block.id] = grid.fittingHeight
        return grid
    }

    func height(for block: Block, width: CGFloat) -> CGFloat? {
        // Шапка и 50 строк по 33 — пока вид не создан.
        heights[block.id] ?? 33 + 50 * 33 + 1
    }
}
