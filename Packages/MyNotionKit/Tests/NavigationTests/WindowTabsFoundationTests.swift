import Foundation
import Testing
@testable import Navigation
import NotesCore

/// Модель вкладок этапа 0 (T021, research R5): одна вкладка — поведение 002; запрос открытия страницы — в активной
/// вкладке или новой справа (новую включает US3); хранение в `window_state.tabs`. Полное поведение — `WindowTabsTests` US3.
@MainActor
@Suite("Вкладки окна: основа")
struct WindowTabsFoundationTests {
    let pageA = UUID.timeOrdered(), pageB = UUID.timeOrdered(), pageC = UUID.timeOrdered()

    @Test("Без сохранённых вкладок — одна вкладка с открытой страницей 002")
    func legacyWindowStateGivesOneTab() {
        let tabs = WindowTabs(state: nil, openPageId: pageA)
        #expect(tabs.items.count == 1)
        #expect(tabs.activePageId == pageA)
        #expect(WindowTabs(state: nil, openPageId: nil).activePageId == nil)
    }

    @Test("Открыть в активной: страница вкладки меняется, вкладок по-прежнему одна; событие «ушли / открыта»")
    func openInActiveTab() {
        let tabs = WindowTabs(state: nil, openPageId: pageA)
        var events: [(UUID?, UUID?)] = []
        tabs.onActivePageChange = { events.append(($0, $1)) }
        tabs.open(PageOpenRequest(pageId: pageB))
        #expect(tabs.items.count == 1 && tabs.activePageId == pageB)
        tabs.open(PageOpenRequest(pageId: pageB))
        #expect(events.count == 1, "та же страница — не новое открытие")
        #expect(events.first?.0 == pageA && events.first?.1 == pageB)
    }

    @Test("Открыть в новой вкладке: справа от текущей, активная прежняя")
    func openInNewTab() {
        let tabs = WindowTabs(state: TabsState(active: 0, items: [Tab(pageId: pageA), Tab(pageId: pageC)]), openPageId: nil)
        tabs.open(PageOpenRequest(pageId: pageB, inNewTab: true))
        #expect(tabs.items.map(\.pageId) == [pageA, pageB, pageC])
        #expect(tabs.activeIndex == 0 && tabs.activePageId == pageA)
    }

    @Test("Сохранённые вкладки читаются и записываются как были; испорченный индекс — первая вкладка")
    func stateRoundTrip() {
        let state = TabsState(active: 1, items: [Tab(pageId: pageA), Tab(pageId: pageB, back: [TabEntry(pageId: pageA)])])
        #expect(WindowTabs(state: state, openPageId: pageC).savedState == state)
        let broken = WindowTabs(state: TabsState(active: 7, items: [Tab(pageId: pageA)]), openPageId: nil)
        #expect(broken.activeIndex == 0 && broken.activePageId == pageA)
        #expect(WindowTabs(state: TabsState(active: 0, items: []), openPageId: pageC).activePageId == pageC, "пустой список — как 002")
    }

    @Test("Запрос открытия: страница, новая вкладка, блок для перехода")
    func openRequest() {
        let block = UUID()
        let request = PageOpenRequest(pageId: pageA, inNewTab: true, revealBlockId: block)
        #expect(request.pageId == pageA && request.inNewTab && request.revealBlockId == block)
        #expect(!PageOpenRequest(pageId: pageA).inNewTab)
    }
}
