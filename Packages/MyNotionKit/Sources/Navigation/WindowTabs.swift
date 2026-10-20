import Foundation
import NotesCore

/// Вкладки окна (research R5): список, активная, открыть страницу в активной или новой, закрыть и вернуть закрытую,
/// переставить, «назад/вперёд»; хранение в `window_state.tabs`.
/// Редактор один — у активной вкладки; неактивная держит только страницу, место прокрутки и свою историю.
@MainActor
public final class WindowTabs {
    /// Сколько закрытых вкладок окна помнит ⇧⌘T (только в памяти).
    public static let closedTabsLimit = 20

    public private(set) var items: [Tab]
    public private(set) var activeIndex: Int
    /// Закрытые вкладки с их местом в полосе; последняя — сверху.
    public private(set) var closedTabs: [(tab: Tab, index: Int)] = []
    /// Ушли со страницы и открыли другую в активной вкладке: запись недавних (US2) слушает это событие.
    public var onActivePageChange: ((_ left: UUID?, _ opened: UUID?) -> Void)?
    /// Список или активная вкладка поменялись: окно сохраняет `savedState`.
    public var onChange: (() -> Void)?
    /// Место прокрутки открытой страницы сейчас (его знает редактор): запоминается, когда активная вкладка уходит
    /// со страницы, и попадает в `savedState`.
    public var currentScroll: (() -> TabScroll?)?
    /// Страница удалена навсегда: её записи «назад/вперёд» пропускаются.
    public var isGone: (UUID) -> Bool = { _ in false }

    /// Без сохранённых вкладок (или с пустым списком) — одна вкладка с `openPageId`, как в 002.
    public init(state: TabsState?, openPageId: UUID?) {
        if let state, !state.items.isEmpty {
            items = state.items
            activeIndex = state.items.indices.contains(state.active) ? state.active : 0
        } else {
            items = [Tab(pageId: openPageId)]
            activeIndex = 0
        }
    }

    public var activeTab: Tab { items[activeIndex] }
    public var activePageId: UUID? { activeTab.pageId }

    public var savedState: TabsState {
        var saved = items
        if activePageId != nil, let scroll = currentScroll?() { saved[activeIndex].scroll = scroll }
        return TabsState(active: activeIndex, items: saved)
    }

    public var canGoBack: Bool { activeTab.canGoBack(isGone: isGone) }
    public var canGoForward: Bool { activeTab.canGoForward(isGone: isGone) }

    // MARK: Открыть

    /// Открыть страницу: в новой вкладке — справа от текущей, активная остаётся; иначе — переход в активной
    /// с записью в её историю.
    public func open(_ request: PageOpenRequest) {
        if request.inNewTab {
            items.insert(Tab(pageId: request.pageId), at: activeIndex + 1)
            onChange?()
            return
        }
        let left = activePageId
        guard items[activeIndex].navigate(to: request.pageId, leaving: leavingScroll()) else { return }
        activePageDidChange(from: left)
    }

    /// ⌘T и «+»: пустая «Новая вкладка» справа от текущей, сразу активная.
    public func newTab() {
        let left = activePageId
        rememberScroll()
        items.insert(Tab(), at: activeIndex + 1)
        activeIndex += 1
        activePageDidChange(from: left)
    }

    // MARK: Назад и вперёд

    @discardableResult
    public func goBack() -> Bool {
        let left = activePageId
        guard items[activeIndex].goBack(leaving: leavingScroll(), isGone: isGone) else { return false }
        activePageDidChange(from: left)
        return true
    }

    @discardableResult
    public func goForward() -> Bool {
        let left = activePageId
        guard items[activeIndex].goForward(leaving: leavingScroll(), isGone: isGone) else { return false }
        activePageDidChange(from: left)
        return true
    }

    // MARK: Переключить и переставить

    /// Щелчок по вкладке.
    public func activate(_ index: Int) {
        guard items.indices.contains(index), index != activeIndex else { return }
        let left = activePageId
        rememberScroll()
        activeIndex = index
        activePageDidChange(from: left)
    }

    /// ⌃⇥: следующая, после последней — первая.
    public func showNextTab() { activate((activeIndex + 1) % items.count) }

    /// ⌃⇧⇥: предыдущая, перед первой — последняя.
    public func showPreviousTab() { activate((activeIndex + items.count - 1) % items.count) }

    /// Перетаскивание вкладки: активной остаётся та же вкладка.
    public func move(from source: Int, to destination: Int) {
        guard items.indices.contains(source), items.indices.contains(destination), source != destination else { return }
        let activeId = activeTab.id
        items.insert(items.remove(at: source), at: destination)
        activeIndex = items.firstIndex { $0.id == activeId } ?? 0
        onChange?()
    }

    // MARK: Закрыть и вернуть

    public enum CloseResult: Equatable, Sendable {
        case closed
        /// Вкладка последняя: закрыть окно (как ⌘W 001); список не меняется.
        case closeWindow
    }

    /// «×» на вкладке. Закрыта активная — активной становится соседняя справа, у крайней — слева.
    @discardableResult
    public func close(at index: Int) -> CloseResult {
        guard items.indices.contains(index) else { return .closed }
        guard items.count > 1 else { return .closeWindow }
        let wasActive = index == activeIndex
        let left = activePageId
        if wasActive { rememberScroll() }
        closedTabs.append((items.remove(at: index), index))
        if closedTabs.count > Self.closedTabsLimit { closedTabs.removeFirst(closedTabs.count - Self.closedTabsLimit) }
        if index < activeIndex || activeIndex == items.count { activeIndex -= 1 }
        if wasActive { activePageDidChange(from: left) } else { onChange?() }
        return .closed
    }

    /// ⌘W.
    @discardableResult
    public func closeActiveTab() -> CloseResult { close(at: activeIndex) }

    /// ⇧⌘T: последняя закрытая вкладка — на прежнее место со своей историей, сразу активная. `false` — закрытых нет.
    @discardableResult
    public func reopenClosedTab() -> Bool {
        guard let (tab, index) = closedTabs.popLast() else { return false }
        let left = activePageId
        rememberScroll()
        let place = min(index, items.count)
        items.insert(tab, at: place)
        activeIndex = place
        activePageDidChange(from: left)
        return true
    }

    // MARK: Внутреннее

    /// Место прокрутки страницы, с которой уходит активная вкладка.
    private func leavingScroll() -> TabScroll? {
        activePageId == nil ? nil : currentScroll?()
    }

    /// Активная вкладка уходит в тень: её место прокрутки — в саму вкладку.
    private func rememberScroll() {
        guard activePageId != nil, let scroll = currentScroll?() else { return }
        items[activeIndex].scroll = scroll
    }

    private func activePageDidChange(from left: UUID?) {
        onChange?()
        if left != activePageId { onActivePageChange?(left, activePageId) }
    }
}
