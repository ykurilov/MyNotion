import AppKit
import NotesCore
import Testing
import VisualStyle
@testable import PageTree

/// Меню блока-ссылки на страницу по правой кнопке: пункты страницы — те же описатели и обработчики окна,
/// что у меню строки панели, и действуют на страницу по ссылке.
@MainActor
@Suite("Меню ссылки на страницу")
struct PageLinkMenuTests {
    let linkedPageId = UUID.timeOrdered()

    private func allHandlers(recording calls: @escaping (PageRowMenuSlot, UUID) -> Void) -> [PageRowMenuSlot: (UUID) -> Void] {
        var handlers: [PageRowMenuSlot: (UUID) -> Void] = [:]
        for slot in PageRowMenuSlot.allCases { handlers[slot] = { calls(slot, $0) } }
        return handlers
    }

    private func menu(isFavorite: Bool = false, footer: String? = "Изменено: сегодня в 18:25, 3 слова",
                      calls: @escaping (PageRowMenuSlot, UUID) -> Void = { _, _ in }) -> ActionMenuView {
        let context = PageRowMenuContext(pageId: linkedPageId, isTemplate: false, isFavorite: isFavorite)
        return ActionMenuView(entries: PageLinkMenu.entries(context: context, handlers: allHandlers(recording: calls), footer: footer),
                              width: Metrics.PageMenu.width)
    }

    @Test("Пункты страницы по группам, как у Notion: иконка, избранное, имя — вкладка, окно — ссылка, копия, перенос, корзина — ИИ")
    func outline() {
        #expect(menu(footer: nil).outline == [
            "Сменить иконку", "Добавить в избранное", "Переименовать", "—",
            "Открыть в новой вкладке", "Открыть в новом окне", "—",
            "Копировать ссылку", "Дублировать", "Переместить в", "Удалить в корзину", "—",
            "Спросить ИИ",
        ])
        #expect(menu(isFavorite: true, footer: nil).outline.contains("Убрать из избранного"))
    }

    @Test("Подвал серым внизу, за чертой, не нажимается")
    func footer() throws {
        let view = menu()
        let label = try #require(view.subviews.last as? NSTextField)
        #expect(label.stringValue == "Изменено: сегодня в 18:25, 3 слова")
        #expect(label.accessibilityIdentifier() == "page-link-menu-footer")
        #expect(view.outline.last == "—", "подвал отделён чертой")
        #expect(!view.rowViews.contains { $0.action.title.hasPrefix("Изменено") })
        #expect(menu(footer: nil).subviews.allSatisfy { !($0 is NSTextField) })
    }

    @Test("Подсказки клавиш — те же, что у меню строки панели")
    func hints() {
        let hints = Dictionary(uniqueKeysWithValues: menu().rowViews.map { ($0.action.title, $0.action.hint) })
        #expect(hints["Копировать ссылку"] == "⌘L")
        #expect(hints["Дублировать"] == "⌘D")
        #expect(hints["Переместить в"] == "⌘⇧P")
    }

    @Test("Дублировать, переименовать, в корзину, избранное, копировать ссылку — обработчики окна со страницей по ссылке",
          arguments: ["Дублировать", "Переименовать", "Удалить в корзину", "Добавить в избранное", "Копировать ссылку",
                      "Сменить иконку", "Открыть в новой вкладке", "Открыть в новом окне", "Переместить в", "Спросить ИИ"])
    func actionsApplyToLinkedPage(title: String) throws {
        var calls: [(PageRowMenuSlot, UUID)] = []
        let view = menu { calls.append(($0, $1)) }
        let row = try #require(view.rowViews.first { $0.action.title == title })
        row.press()
        #expect(calls.count == 1)
        #expect(calls.first?.1 == linkedPageId)
    }

    @Test("Пункт без обработчика окна не показывается; черта между пустыми группами не повторяется")
    func missingHandlers() {
        let context = PageRowMenuContext(pageId: linkedPageId, isTemplate: false, isFavorite: false)
        let view = ActionMenuView(entries: PageLinkMenu.entries(context: context, handlers: [.rename: { _ in }, .trash: { _ in }], footer: nil),
                                  width: Metrics.PageMenu.width)
        #expect(view.outline == ["Переименовать", "—", "Удалить в корзину"])
    }

    @Test("Новые места меню ссылки не попали в меню строки панели")
    func sidebarUnchanged() {
        let slots = PageRowMenuItem.all.map(\.slot)
        #expect(!slots.contains(.changeIcon) && !slots.contains(.openInNewWindow) && !slots.contains(.askAI))
    }
}
