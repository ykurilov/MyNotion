import AppKit
import NotesCore
import Testing
import VisualStyle
@testable import PageTree

/// Реестры панели (plan.md, Structure Decision; contracts/pages-ui.md, «Боковая панель»): разделы и меню строки
/// страницы собираются из описателей, каждая история добавляет свой файл.
@MainActor
@Suite("Реестры панели")
struct SidebarRegistryTests {
    let pageId = UUID.timeOrdered()

    @Test("Разделы панели — «Недавние», «Избранное», «Шаблоны», «Страницы», в каком бы порядке ни пришли")
    func sectionOrder() {
        let sections = [SidebarSection(id: .pages, title: "Страницы"), SidebarSection(id: .templates, title: "Шаблоны"),
                        SidebarSection(id: .recent, title: "Недавние"), SidebarSection(id: .favorites, title: "Избранное")]
        #expect(SidebarSection.ordered(sections).map(\.title) == ["Недавние", "Избранное", "Шаблоны", "Страницы"])
        #expect(SidebarSection.pages.id == .pages && SidebarSection.pages.title == "Страницы")
        #expect(SidebarSection.ordered([]).map(\.id) == [.pages], "раздел «Страницы» есть всегда")
    }

    private func titles(_ menu: ActionMenuView) -> [String] {
        menu.outline
    }

    @Test("Меню строки 001 из описателей: Переименовать, Добавить подстраницу, —, Удалить в корзину")
    func rowMenuOf001() {
        let menu = PageRowMenu.make(items: PageRowMenuItem.all, context: PageRowMenuContext(pageId: pageId, isTemplate: false, isFavorite: false),
                                    handlers: [.rename: { _ in }, .addSubpage: { _ in }, .trash: { _ in }])
        #expect(titles(menu) == ["Переименовать", "Добавить подстраницу", "—", "Удалить в корзину"])
    }

    @Test("Полное меню — в порядке контракта; пункт без обработчика окна не показывается")
    func fullRowMenuOrder() {
        func fake(_ slot: PageRowMenuSlot, _ title: String) -> PageRowMenuItem {
            PageRowMenuItem(slot: slot) { _ in title }
        }
        let items = [fake(.trash, "Удалить в корзину"), fake(.template, "Сделать шаблоном"), fake(.openInNewTab, "Открыть в новой вкладке"),
                     fake(.addSubpage, "Добавить подстраницу"), fake(.rename, "Переименовать"), fake(.moveTo, "Переместить в"),
                     fake(.duplicate, "Дублировать"), fake(.favorite, "Добавить в избранное"), fake(.newFromTemplate, "Новая страница по шаблону")]
        var handlers: [PageRowMenuSlot: (UUID) -> Void] = [:]
        for slot in PageRowMenuSlot.allCases { handlers[slot] = { _ in } }
        let context = PageRowMenuContext(pageId: pageId, isTemplate: true, isFavorite: false)
        #expect(titles(PageRowMenu.make(items: items, context: context, handlers: handlers)) == [
            "Новая страница по шаблону", "Добавить в избранное", "Дублировать", "Переместить в", "Переименовать", "Добавить подстраницу",
            "Открыть в новой вкладке", "Сделать шаблоном", "—", "Удалить в корзину",
        ])
        handlers[.duplicate] = nil
        #expect(!titles(PageRowMenu.make(items: items, context: context, handlers: handlers)).contains("Дублировать"))
    }

    @Test("Пункт меню строки вызывает обработчик окна со своей страницей")
    func rowMenuRunsHandler() throws {
        var trashed: [UUID] = []
        let menu = PageRowMenu.make(items: PageRowMenuItem.all, context: PageRowMenuContext(pageId: pageId, isTemplate: false, isFavorite: false),
                                    handlers: [.trash: { trashed.append($0) }])
        let item = try #require(menu.rowViews.first { $0.action.title == "Удалить в корзину" })
        item.press()
        #expect(trashed == [pageId])
    }
}
