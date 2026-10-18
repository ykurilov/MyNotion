import AppKit
import Testing
import VisualStyle
@testable import PageSearch

/// Геометрия выдачи поиска по снимку Notion 7.38.1 (18.10.2026): заголовок «Найдено: N» над строками —
/// с того же края, что иконки; пусто — «Ничего не найдено» и пояснение по центру карточки.
@Suite("Выдача поиска: заголовок и пустое состояние")
@MainActor
struct SearchResultsLayoutTests {
    static let width = Metrics.SearchResults.width

    @Test("Ничего не найдено: две строки по центру карточки, без колонок выдачи")
    func emptyStateIsCentered() throws {
        let view = SearchResultsView()
        view.show([], selectedIndex: 0)
        let ink = try Self.inkRows(of: view)

        #expect(ink.count == 2, "строк текста: \(ink.count)")
        for line in ink {
            #expect(abs(line.midX - Self.width / 2) <= 1.5, "строка \(line), середина карточки \(Self.width / 2)")
        }
        #expect(abs(view.contentHeight - Metrics.SearchResults.emptyStateHeight) < 0.5)
        let block = ink[0].union(ink[1])
        #expect(abs(block.midY - view.contentHeight / 2) <= 1.5, "текст \(block) в высоте \(view.contentHeight)")
    }

    @Test("Над строками — заголовок «Найдено: N» с края иконок; строки ниже заголовка")
    func headerAboveRows() throws {
        let view = SearchResultsView()
        let result = PageSearchResult(pageId: UUID(), title: "Кот", icon: nil, path: [], titleHighlights: [], snippet: nil)
        view.show([result], selectedIndex: 0)
        #expect(SearchResultsView.headerText(count: 1) == "Найдено: 1")

        let headerHeight = Metrics.SearchResults.headerHeight
        #expect(abs(view.contentHeight - (headerHeight + SearchResultsView.rowHeight(result))) < 0.5)
        let ink = try Self.inkRows(of: view)
        let header = try #require(ink.first)
        #expect(header.maxY <= headerHeight, "заголовок \(header)")
        let iconX = Metrics.PopupMenu.rowInset + Metrics.PopupMenu.rowHorizontalPadding
        #expect(abs(header.minX - iconX) <= 1.5, "заголовок с \(header.minX), иконки с \(iconX)")
    }

    @Test("Длинная выдача прокручивается только по вертикали; у первой строки виден заголовок")
    func longResultsScrollVertically() throws {
        let panel = SearchResultsPanel()
        let results = (0..<20).map { index in
            PageSearchResult(pageId: UUID(), title: "Страница \(index)", icon: nil, path: ["Родитель"], titleHighlights: [],
                             snippet: SearchSnippet(text: "кусок текста", highlights: []))
        }
        panel.resultsView.show(results, selectedIndex: 0)
        let margin = SearchResultsPanel.shadowMargin
        panel.setFrame(NSRect(x: 0, y: 0, width: Self.width + 2 * margin, height: 300 + 2 * margin), display: false)
        panel.contentView?.layoutSubtreeIfNeeded()
        let clip = try #require(panel.resultsView.enclosingScrollView?.contentView)
        panel.resultsView.scrollSelectionToVisible()
        #expect(clip.bounds.minX == 0)
        #expect(panel.resultsView.frame.width == Self.width, "строки уже карточки: \(panel.resultsView.frame.width)")
        #expect(clip.bounds.minY == -Metrics.SearchResults.verticalPadding, "сверху \(clip.bounds.minY): заголовок спрятан")

        panel.resultsView.selectedIndex = 19
        panel.resultsView.scrollSelectionToVisible()
        #expect(clip.bounds.minX == 0)
        #expect(clip.bounds.maxY >= panel.resultsView.contentHeight, "последняя строка не видна: \(clip.bounds)")
    }

    /// Строки «чернил»: прямоугольники непрозрачных точек, разделённые пустыми полосами. Начало сверху.
    private static func inkRows(of view: SearchResultsView) throws -> [NSRect] {
        view.frame = NSRect(x: 0, y: 0, width: width, height: view.contentHeight)
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / width
        var rows: [NSRect] = []
        var current: (minX: Int, maxX: Int, minY: Int, maxY: Int)?
        for y in 0..<rep.pixelsHigh {
            var minX = Int.max, maxX = -1
            for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.3 {
                minX = min(minX, x); maxX = max(maxX, x)
            }
            if maxX >= 0 {
                if var line = current {
                    line.minX = min(line.minX, minX); line.maxX = max(line.maxX, maxX); line.maxY = y
                    current = line
                } else {
                    current = (minX, maxX, y, y)
                }
            } else if let line = current {
                rows.append(NSRect(x: CGFloat(line.minX) / scale, y: CGFloat(line.minY) / scale,
                                   width: CGFloat(line.maxX - line.minX + 1) / scale, height: CGFloat(line.maxY - line.minY + 1) / scale))
                current = nil
            }
        }
        return rows
    }
}
