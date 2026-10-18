import AppKit
import NotesCore
import Testing
@testable import PageTree

/// Список стал ниже (внизу панели появился значок синхронизации): выбранная строка не остаётся срезанной у края —
/// иначе её подсветка торчит бледной полоской над разделителем (проверка интерфейса, раунд 4, № 15).
@MainActor
@Suite("Выбранная строка дерева видна целиком")
struct SelectedRowVisibilityTests {
    @Test("Видимая часть списка уменьшилась — выбранная строка докручивается целиком")
    func selectedRowStaysVisibleWhenListShrinks() throws {
        let now = Date()
        var key: FractionalSortKey?
        let pages = (0..<30).map { index -> Page in
            key = .between(key, nil)
            return Page(title: "Страница \(index)", sortKey: key!, createdAt: now, updatedAt: now)
        }
        let outline = PageOutlineView(frame: NSRect(x: 0, y: 0, width: 250, height: 300))
        let dataSource = PageOutlineDataSource(actions: PageTreeActions(select: { _ in }, rename: { _, _ in }, move: { _, _, _ in },
                                                                        moveToTrash: { _ in }, addSubpage: { _ in },
                                                                        collapsedPagesChanged: { _ in }))
        dataSource.attach(to: outline)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 250, height: 310))
        scroll.documentView = outline
        dataSource.show(PageTreeSnapshot(allPages: pages), collapsedPageIds: [], selectedPageId: nil)
        // Выбрана последняя целиком видимая строка.
        let visible = outline.rows(in: outline.visibleRect)
        let lastRow = visible.location + visible.length - 1
        let selected = outline.rect(ofRow: lastRow).maxY <= outline.visibleRect.maxY ? lastRow : lastRow - 1
        dataSource.select(pages[selected].id)
        #expect(outline.visibleRect.contains(outline.rect(ofRow: selected)))

        scroll.setFrameSize(NSSize(width: 250, height: 280))
        scroll.layoutSubtreeIfNeeded()

        let rowRect = outline.rect(ofRow: selected)
        #expect(outline.visibleRect.minY <= rowRect.minY && rowRect.maxY <= outline.visibleRect.maxY + 0.5,
                "Строка срезана: \(rowRect) при видимом \(outline.visibleRect)")
        withExtendedLifetime(dataSource) {}
    }
}
