import Foundation
import NotesCore

/// Вкладки окна (research R5): список, активная, открыть страницу в активной или новой; хранение в `window_state.tabs`.
/// Редактор один — у активной вкладки; неактивная держит только страницу, место прокрутки и свою историю.
/// Этап 0: одна вкладка ведёт себя как окно 002. Полосу вкладок, историю «назад/вперёд» и закрытие пишет US3.
@MainActor
public final class WindowTabs {
    public private(set) var items: [Tab]
    public private(set) var activeIndex: Int
    /// Ушли со страницы и открыли другую в активной вкладке: запись недавних (US2) слушает это событие.
    public var onActivePageChange: ((_ left: UUID?, _ opened: UUID?) -> Void)?
    /// Список или активная вкладка поменялись: окно сохраняет `savedState`.
    public var onChange: (() -> Void)?

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

    public var savedState: TabsState { TabsState(active: activeIndex, items: items) }

    /// Открыть страницу: в новой вкладке — справа от текущей, активная остаётся; иначе — в активной.
    public func open(_ request: PageOpenRequest) {
        if request.inNewTab {
            items.insert(Tab(pageId: request.pageId), at: activeIndex + 1)
            onChange?()
            return
        }
        let left = activePageId
        guard left != request.pageId else { return }
        items[activeIndex].pageId = request.pageId
        items[activeIndex].scroll = nil
        onChange?()
        onActivePageChange?(left, request.pageId)
    }
}
