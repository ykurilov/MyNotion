import Foundation
import Testing
@testable import Navigation
import NotesCore

/// Вкладки окна (T047, contracts/page-operations.md, «Вкладки и история»; research R5).
@MainActor
@Suite("Вкладки окна")
struct WindowTabsTests {
    let pageA = UUID.timeOrdered(), pageB = UUID.timeOrdered(), pageC = UUID.timeOrdered(), pageD = UUID.timeOrdered()

    private func tabs(_ pages: [UUID?], active: Int = 0) -> WindowTabs {
        WindowTabs(state: TabsState(active: active, items: pages.map { Tab(pageId: $0) }), openPageId: nil)
    }

    @Test("⌘-щелчок: новая вкладка сразу справа от текущей, активная не меняется, страница текущей та же")
    func commandClickOpensRightOfCurrent() {
        let tabs = tabs([pageA, pageB], active: 0)
        var changes = 0
        tabs.onActivePageChange = { _, _ in changes += 1 }
        tabs.open(PageOpenRequest(pageId: pageC, inNewTab: true))
        tabs.open(PageOpenRequest(pageId: pageD, inNewTab: true))
        #expect(tabs.items.map(\.pageId) == [pageA, pageD, pageC, pageB])
        #expect(tabs.activeIndex == 0 && tabs.activePageId == pageA)
        #expect(changes == 0, "активная страница не менялась")
        #expect(tabs.items[1].back.isEmpty, "у новой вкладки своя пустая история")
    }

    @Test("⌘T и «+» (как Notion 7.39): выбранная в окне поиска страница — новой вкладкой в конце, сразу активной")
    func newTabOpensAtEndAndActive() {
        let tabs = tabs([pageA, pageB], active: 0)
        tabs.openNewTab(pageC)
        #expect(tabs.items.map(\.pageId) == [pageA, pageB, pageC])
        #expect(tabs.activeIndex == 2 && tabs.activePageId == pageC)
        #expect(tabs.activeTab.back.isEmpty, "у новой вкладки своя пустая история")
    }

    @Test("Страницу прокрутили в самый верх — старое место вкладки забыто: и при переключении, и в сохранённых вкладках")
    func topOfPageClearsRememberedPlace() {
        let tabs = tabs([pageA, pageB])
        let placeA = TabScroll(blockId: UUID(), offset: 40)
        var place: TabScroll? = placeA
        tabs.currentScroll = { place }
        tabs.activate(1)
        #expect(tabs.items[0].scroll == placeA)
        tabs.activate(0)
        place = nil
        #expect(tabs.savedState.items[0].scroll == nil, "сохранится старое место, а страница наверху")
        tabs.activate(1)
        #expect(tabs.items[0].scroll == nil, "вернёмся не наверх, а на старое место")
    }

    @Test("Редактора этой страницы нет (заглушка корзины, страница ещё открывается) — место вкладки не трогается")
    func noEditorKeepsRememberedPlace() {
        let tabs = tabs([pageA, pageB])
        let placeA = TabScroll(blockId: UUID(), offset: 40)
        let other = TabScroll(blockId: UUID(), offset: 7)
        tabs.currentScroll = { placeA }
        tabs.activate(1)
        tabs.activate(0)
        // Редактор показывает другую страницу (прошлый, ещё не отпущенный): его место — не место этой вкладки.
        tabs.currentScroll = { other }
        tabs.showsEditor = { _ in false }
        #expect(tabs.savedState.items[0].scroll == placeA)
        tabs.activate(1)
        #expect(tabs.items[0].scroll == placeA)
        tabs.activate(0)
        tabs.open(PageOpenRequest(pageId: pageC))
        #expect(tabs.activeTab.back == [TabEntry(pageId: pageA, scroll: placeA)])
    }

    @Test("«Показать все» в «Недавних»: «Недавние» в этой же вкладке, «назад» возвращает страницу")
    func recentPagesInActiveTab() {
        let tabs = tabs([pageA, pageB], active: 0)
        let placeA = TabScroll(blockId: UUID(), offset: 9)
        tabs.currentScroll = { placeA }
        tabs.showRecentPages()
        #expect(tabs.items.count == 2 && tabs.activePageId == nil)
        #expect(tabs.activeTab.back == [TabEntry(pageId: pageA, scroll: placeA)])
        tabs.showRecentPages()
        #expect(tabs.activeTab.back.count == 1, "уже «Недавние» — записи не добавляется")
        tabs.open(PageOpenRequest(pageId: pageC))
        #expect(tabs.activePageId == pageC && tabs.activeTab.back.map(\.pageId) == [pageA], "«Недавние» в историю не пишутся")
        #expect(tabs.goBack() && tabs.activePageId == pageA && tabs.activeTab.scroll == placeA)
    }

    @Test("Переход в активной вкладке пишет историю с местом прокрутки ухода; назад и вперёд — по ней")
    func navigationInActiveTabUsesHistory() {
        let tabs = tabs([pageA])
        let placeA = TabScroll(blockId: UUID(), offset: 50)
        var place: TabScroll? = placeA
        tabs.currentScroll = { place }
        tabs.open(PageOpenRequest(pageId: pageB))
        place = nil
        #expect(tabs.activeTab.back == [TabEntry(pageId: pageA, scroll: placeA)])
        #expect(tabs.canGoBack && !tabs.canGoForward)
        #expect(tabs.goBack())
        #expect(tabs.activePageId == pageA && tabs.activeTab.scroll == placeA)
        #expect(tabs.goForward())
        #expect(tabs.activePageId == pageB)
    }

    @Test("Назад пропускает страницы, удалённые навсегда")
    func backSkipsGonePages() {
        let tabs = tabs([pageA])
        tabs.open(PageOpenRequest(pageId: pageB))
        tabs.open(PageOpenRequest(pageId: pageC))
        tabs.isGone = { $0 == pageB }
        #expect(tabs.goBack())
        #expect(tabs.activePageId == pageA)
    }

    @Test("Щелчок по вкладке, ⌃⇥ и ⌃⇧⇥ — по кругу; место прокрутки ушедшей вкладки запоминается")
    func switchingTabs() {
        let tabs = tabs([pageA, pageB, pageC])
        let placeA = TabScroll(blockId: UUID(), offset: 12)
        tabs.currentScroll = { placeA }
        var events: [(UUID?, UUID?)] = []
        tabs.onActivePageChange = { events.append(($0, $1)) }
        tabs.activate(2)
        #expect(tabs.activeIndex == 2 && tabs.items[0].scroll == placeA)
        tabs.currentScroll = { nil }
        tabs.showNextTab()
        #expect(tabs.activeIndex == 0, "после последней — первая")
        tabs.showPreviousTab()
        #expect(tabs.activeIndex == 2, "перед первой — последняя")
        tabs.showPreviousTab()
        #expect(tabs.activeIndex == 1)
        #expect(events.map(\.1) == [pageC, pageA, pageC, pageB])
        tabs.activate(1)
        #expect(events.count == 4, "та же вкладка — не переключение")
    }

    @Test("Закрытие: неактивной — активная прежняя; активной — соседняя справа, у крайней — слева")
    func closingTabs() {
        let tabs = tabs([pageA, pageB, pageC, pageD], active: 1)
        #expect(tabs.close(at: 3) == .closed)
        #expect(tabs.items.map(\.pageId) == [pageA, pageB, pageC] && tabs.activePageId == pageB)
        #expect(tabs.close(at: 1) == .closed)
        #expect(tabs.activePageId == pageC, "справа от закрытой")
        #expect(tabs.close(at: 1) == .closed)
        #expect(tabs.activePageId == pageA, "справа никого — слева")
    }

    @Test("⌘W на последней вкладке закрывает окно, вкладка остаётся в списке")
    func closingLastTabClosesWindow() {
        let tabs = tabs([pageA])
        #expect(tabs.closeActiveTab() == .closeWindow)
        #expect(tabs.items.map(\.pageId) == [pageA])
    }

    @Test("⇧⌘T возвращает последнюю закрытую на прежнее место со своей историей и делает активной")
    func reopenClosedTab() {
        let tabs = tabs([pageA, pageB, pageC], active: 0)
        tabs.activate(1)
        tabs.open(PageOpenRequest(pageId: pageD))
        let closed = tabs.activeTab
        #expect(closed.back.map(\.pageId) == [pageB])
        tabs.closeActiveTab()
        tabs.activate(0)
        #expect(tabs.reopenClosedTab())
        #expect(tabs.items.map(\.pageId) == [pageA, pageD, pageC])
        #expect(tabs.activeIndex == 1 && tabs.activeTab == closed)
        #expect(!tabs.reopenClosedTab(), "закрытых больше нет")
    }

    @Test("Закрытых помнится 20, вернуть можно по очереди с последней")
    func closedTabsLimit() {
        let tabs = tabs([pageA])
        var opened: [UUID] = []
        for _ in 0..<25 {
            let page = UUID.timeOrdered()
            opened.append(page)
            tabs.open(PageOpenRequest(pageId: page, inNewTab: true))
            tabs.close(at: 1)
        }
        var reopened: [UUID?] = []
        while tabs.reopenClosedTab() { reopened.append(tabs.activePageId) }
        #expect(reopened == opened.suffix(WindowTabs.closedTabsLimit).reversed().map { $0 })
    }

    @Test("Перестановка: порядок меняется, активной остаётся та же вкладка")
    func reorderKeepsActiveTab() {
        let tabs = tabs([pageA, pageB, pageC], active: 0)
        tabs.move(from: 0, to: 2)
        #expect(tabs.items.map(\.pageId) == [pageB, pageC, pageA])
        #expect(tabs.activePageId == pageA && tabs.activeIndex == 2)
        tabs.move(from: 2, to: 0)
        #expect(tabs.items.map(\.pageId) == [pageA, pageB, pageC] && tabs.activeIndex == 0)
        tabs.move(from: 1, to: 2)
        #expect(tabs.items.map(\.pageId) == [pageA, pageC, pageB] && tabs.activeIndex == 0)
    }

    @Test("Хранение: порядок, активная, истории и место прокрутки активной — как были после перезапуска")
    func savedStateRoundTrip() throws {
        let tabs = tabs([pageA])
        tabs.open(PageOpenRequest(pageId: pageB))
        tabs.open(PageOpenRequest(pageId: pageC, inNewTab: true))
        let place = TabScroll(blockId: UUID(), offset: 33)
        tabs.currentScroll = { place }
        var saved: [TabsState] = []
        tabs.onChange = { saved.append(tabs.savedState) }
        tabs.activate(1)
        let state = tabs.savedState
        #expect(saved.last == state)
        #expect(state.active == 1 && state.items.map(\.pageId) == [pageB, pageC])
        #expect(state.items[0].scroll == place && state.items[0].back.map(\.pageId) == [pageA])

        // `window_state.tabs` — JSON: прочитанное из базы даёт те же вкладки.
        let json = try JSONEncoder().encode(state)
        let restored = WindowTabs(state: try JSONDecoder().decode(TabsState.self, from: json), openPageId: pageD)
        #expect(restored.savedState == state)
        #expect(restored.activePageId == pageC)
    }

    @Test("Каждое изменение списка или активной — сигнал записать")
    func changesAreReported() {
        let tabs = tabs([pageA, pageB])
        var count = 0
        tabs.onChange = { count += 1 }
        tabs.openNewTab(pageC)
        tabs.activate(0)
        tabs.move(from: 0, to: 1)
        tabs.close(at: 0)
        tabs.reopenClosedTab()
        tabs.showRecentPages()
        tabs.open(PageOpenRequest(pageId: pageD))
        tabs.goBack()
        #expect(count == 8)
    }
}
