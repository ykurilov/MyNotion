import Foundation
import Testing
@testable import Navigation
import NotesCore

/// История «назад/вперёд» вкладки (T046, contracts/page-operations.md, «Вкладки и история»; research R6).
@Suite("История вкладки")
struct NavigationHistoryTests {
    let pageA = UUID.timeOrdered(), pageB = UUID.timeOrdered(), pageC = UUID.timeOrdered(), pageD = UUID.timeOrdered()
    let notGone: (UUID) -> Bool = { _ in false }

    private func scroll(_ offset: Double) -> TabScroll { TabScroll(blockId: UUID(), offset: offset) }

    @Test("Переход: прежняя страница с местом прокрутки — в «назад», «вперёд» очищается")
    func navigatePushesBackAndClearsForward() {
        var tab = Tab(pageId: pageA, forward: [TabEntry(pageId: pageD)])
        let placeA = scroll(120)
        do { let moved = tab.navigate(to: pageB, leaving: placeA); #expect(moved) }
        #expect(tab.pageId == pageB && tab.scroll == nil)
        #expect(tab.back == [TabEntry(pageId: pageA, scroll: placeA)])
        #expect(tab.forward.isEmpty)
    }

    @Test("Повторный выбор той же страницы записи не добавляет")
    func samePageAddsNothing() {
        var tab = Tab(pageId: pageA, back: [TabEntry(pageId: pageC)], forward: [TabEntry(pageId: pageD)])
        do { let moved = tab.navigate(to: pageA, leaving: scroll(10)); #expect(!moved) }
        #expect(tab.back == [TabEntry(pageId: pageC)] && tab.forward == [TabEntry(pageId: pageD)])
    }

    @Test("Из «Новой вкладки» в страницу: в «назад» пусто — пустой вкладки в истории нет")
    func navigateFromNewTab() {
        var tab = Tab(pageId: nil)
        do { let moved = tab.navigate(to: pageA, leaving: nil); #expect(moved) }
        #expect(tab.pageId == pageA && tab.back.isEmpty)
    }

    @Test("Назад и вперёд переносят запись между стопками и возвращают место прокрутки")
    func backAndForwardMoveEntriesWithScroll() {
        var tab = Tab(pageId: pageA)
        let placeA = scroll(300), placeB = scroll(40), placeC = scroll(7)
        tab.navigate(to: pageB, leaving: placeA)
        tab.navigate(to: pageC, leaving: placeB)
        #expect(tab.canGoBack(isGone: notGone) && !tab.canGoForward(isGone: notGone))

        do { let moved = tab.goBack(leaving: placeC, isGone: notGone); #expect(moved) }
        #expect(tab.pageId == pageB && tab.scroll == placeB)
        do { let moved = tab.goBack(leaving: placeB, isGone: notGone); #expect(moved) }
        #expect(tab.pageId == pageA && tab.scroll == placeA)
        let wentBack = tab.goBack(leaving: nil, isGone: notGone)
        #expect(!tab.canGoBack(isGone: notGone) && !wentBack, "назад некуда")
        #expect(tab.pageId == pageA)

        do { let moved = tab.goForward(leaving: placeA, isGone: notGone); #expect(moved) }
        #expect(tab.pageId == pageB && tab.scroll == placeB)
        #expect(tab.back == [TabEntry(pageId: pageA, scroll: placeA)])
        #expect(tab.forward == [TabEntry(pageId: pageC, scroll: placeC)])
    }

    @Test("Переход после «назад» очищает «вперёд»")
    func navigateAfterBackClearsForward() {
        var tab = Tab(pageId: pageA)
        tab.navigate(to: pageB, leaving: nil)
        tab.goBack(leaving: nil, isGone: notGone)
        #expect(tab.canGoForward(isGone: notGone))
        tab.navigate(to: pageC, leaving: nil)
        #expect(!tab.canGoForward(isGone: notGone))
        #expect(tab.back.map(\.pageId) == [pageA])
    }

    @Test("Лимит 50: старые записи уходят с дальнего конца")
    func historyLimit() {
        var tab = Tab(pageId: UUID.timeOrdered())
        var pages: [UUID] = []
        for _ in 0..<60 {
            let next = UUID.timeOrdered()
            pages.append(tab.pageId!)
            tab.navigate(to: next, leaving: nil)
        }
        #expect(tab.back.count == Tab.historyLimit)
        #expect(tab.back.map(\.pageId) == Array(pages.suffix(Tab.historyLimit)), "остались 50 последних")
        for _ in 0..<60 { tab.goBack(leaving: nil, isGone: notGone) }
        #expect(tab.forward.count == Tab.historyLimit && tab.back.isEmpty)
    }

    @Test("Записи страниц, удалённых навсегда, пропускаются и выбрасываются; страница в корзине — нет")
    func skipsPagesDeletedForever() {
        var tab = Tab(pageId: pageA)
        tab.navigate(to: pageB, leaving: nil)
        tab.navigate(to: pageC, leaving: nil)
        tab.navigate(to: pageD, leaving: nil)
        // pageC стёрта навсегда, pageB — в корзине (её открывает заглушка «Страница в корзине»).
        let gone: (UUID) -> Bool = { $0 == pageC }
        do { let moved = tab.goBack(leaving: nil, isGone: gone); #expect(moved) }
        #expect(tab.pageId == pageB, "стёртая пропущена, страница в корзине — нет")
        #expect(tab.back.map(\.pageId) == [pageA])
        #expect(tab.forward.map(\.pageId) == [pageD])

        var onlyGone = Tab(pageId: pageB, back: [TabEntry(pageId: pageC)])
        #expect(!onlyGone.canGoBack(isGone: gone))
        do { let moved = onlyGone.goBack(leaving: nil, isGone: gone); #expect(!moved) }
        #expect(onlyGone.pageId == pageB && onlyGone.back.isEmpty, "стёртые записи выброшены, страница прежняя")
    }

    @Test("Вперёд тоже пропускает стёртые")
    func forwardSkipsGone() {
        var tab = Tab(pageId: pageA, forward: [TabEntry(pageId: pageC), TabEntry(pageId: pageB)])
        do { let moved = tab.goForward(leaving: nil, isGone: { $0 == pageB }); #expect(moved) }
        #expect(tab.pageId == pageC && tab.forward.isEmpty)
    }
}
