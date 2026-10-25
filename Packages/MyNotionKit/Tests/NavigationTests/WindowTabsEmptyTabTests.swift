import Foundation
import Testing
@testable import Navigation
import NotesCore

/// Пустая вкладка — `mynotion tab new` (005, этап 6): как «+» без выбора страницы, показывает «Недавние».
@MainActor
@Suite("Пустая вкладка")
struct WindowTabsEmptyTabTests {
    let pageA = UUID.timeOrdered(), pageB = UUID.timeOrdered()

    private func tabs(_ pages: [UUID?], active: Int = 0) -> WindowTabs {
        WindowTabs(state: TabsState(active: active, items: pages.map { Tab(pageId: $0) }), openPageId: nil)
    }

    @Test("Пустая вкладка встаёт в конец и сразу активна, у неё своя пустая история")
    func emptyTabOpensAtEndAndActive() {
        let tabs = tabs([pageA, pageB], active: 0)
        tabs.openEmptyTab()
        #expect(tabs.items.map(\.pageId) == [pageA, pageB, nil])
        #expect(tabs.activeIndex == 2 && tabs.activePageId == nil)
        #expect(tabs.activeTab.back.isEmpty)
    }

    @Test("Уход со страницы в пустую вкладку сообщает записи недавних; возврат на вкладку — тоже")
    func reportsPageChanges() {
        let tabs = tabs([pageA], active: 0)
        var changes: [(UUID?, UUID?)] = []
        tabs.onActivePageChange = { changes.append(($0, $1)) }
        var saved = 0
        tabs.onChange = { saved += 1 }
        tabs.openEmptyTab()
        tabs.activate(0)
        #expect(changes.count == 2)
        #expect(changes[0].0 == pageA && changes[0].1 == nil)
        #expect(changes[1].0 == nil && changes[1].1 == pageA)
        #expect(saved == 2)
    }

    @Test("Закрытая пустая вкладка возвращается на своё место")
    func closedEmptyTabComesBack() {
        let tabs = tabs([pageA], active: 0)
        tabs.openEmptyTab()
        tabs.close(at: 1)
        #expect(tabs.reopenClosedTab())
        #expect(tabs.items.map(\.pageId) == [pageA, nil] && tabs.activeIndex == 1)
    }
}
