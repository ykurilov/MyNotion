import Foundation
import NotesCore

/// История «назад/вперёд» вкладки (research R6): две стопки записей «страница + место прокрутки», до 50 в каждой.
/// Верх стопки — последний элемент. Записи страниц, удалённых навсегда, пропускаются и выбрасываются;
/// страница в корзине — обычная запись (её открывает заглушка «Страница в корзине»).
extension Tab {
    /// Переход в этой вкладке (панель, поиск, ссылка, недавние): текущая запись — в «назад», «вперёд» очищается.
    /// Та же страница — ничего. `false` — перехода не было.
    @discardableResult
    public mutating func navigate(to pageId: UUID, leaving scroll: TabScroll?) -> Bool {
        guard pageId != self.pageId else { return false }
        if let current = self.pageId { Self.push(TabEntry(pageId: current, scroll: scroll), onto: &back) }
        forward.removeAll()
        self.pageId = pageId
        self.scroll = nil
        return true
    }

    /// «Показать все» в «Недавних» (как Library в Notion 7.39): вкладка показывает «Недавние», страница — в «назад».
    /// Сами «Недавние» в историю не пишутся. Уже «Недавние» — ничего.
    @discardableResult
    public mutating func showRecentPages(leaving scroll: TabScroll?) -> Bool {
        guard let current = pageId else { return false }
        Self.push(TabEntry(pageId: current, scroll: scroll), onto: &back)
        forward.removeAll()
        pageId = nil
        self.scroll = nil
        return true
    }

    @discardableResult
    public mutating func goBack(leaving scroll: TabScroll?, isGone: (UUID) -> Bool) -> Bool {
        guard let entry = Self.popLive(&back, isGone: isGone) else { return false }
        if let current = pageId { Self.push(TabEntry(pageId: current, scroll: scroll), onto: &forward) }
        open(entry)
        return true
    }

    @discardableResult
    public mutating func goForward(leaving scroll: TabScroll?, isGone: (UUID) -> Bool) -> Bool {
        guard let entry = Self.popLive(&forward, isGone: isGone) else { return false }
        if let current = pageId { Self.push(TabEntry(pageId: current, scroll: scroll), onto: &back) }
        open(entry)
        return true
    }

    public func canGoBack(isGone: (UUID) -> Bool) -> Bool { back.contains { !isGone($0.pageId) } }
    public func canGoForward(isGone: (UUID) -> Bool) -> Bool { forward.contains { !isGone($0.pageId) } }

    private mutating func open(_ entry: TabEntry) {
        pageId = entry.pageId
        scroll = entry.scroll
    }

    /// Верхняя запись живой страницы; записи стёртых страниц по дороге выбрасываются.
    private static func popLive(_ stack: inout [TabEntry], isGone: (UUID) -> Bool) -> TabEntry? {
        while let entry = stack.popLast() {
            if !isGone(entry.pageId) { return entry }
        }
        return nil
    }

    private static func push(_ entry: TabEntry, onto stack: inout [TabEntry]) {
        stack.append(entry)
        if stack.count > historyLimit { stack.removeFirst(stack.count - historyLimit) }
    }
}
