import AppKit
import NotesCore

/// Место пункта в меню строки страницы панели (contracts/pages-ui.md, «Боковая панель»), по порядку.
public enum PageRowMenuSlot: Int, CaseIterable, Comparable, Sendable {
    case newFromTemplate, favorite, duplicate, moveTo, rename, addSubpage, openInNewTab, template, trash

    public static func < (lhs: PageRowMenuSlot, rhs: PageRowMenuSlot) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Что пункт знает о строке.
public struct PageRowMenuContext: Sendable {
    public let pageId: UUID
    public let isTemplate: Bool
    public let isFavorite: Bool

    public init(pageId: UUID, isTemplate: Bool, isFavorite: Bool) {
        self.pageId = pageId
        self.isTemplate = isTemplate
        self.isFavorite = isFavorite
    }
}

/// Описатель пункта меню строки: место и название (`nil` — пункт этой строке не нужен). Действие — обработчик окна
/// для места (`PageTreeActions.rowMenuHandlers`); пункт без обработчика не показывается.
/// Пункт — файл в `PageRowMenu/`; пункты будущих историй — пустые заготовки, история заменяет свой файл.
public struct PageRowMenuItem: Sendable {
    public let slot: PageRowMenuSlot
    public let title: @Sendable (PageRowMenuContext) -> String?

    public init(slot: PageRowMenuSlot, title: @escaping @Sendable (PageRowMenuContext) -> String?) {
        self.slot = slot
        self.title = title
    }

    /// Все пункты по местам.
    public static var all: [PageRowMenuItem] {
        [newFromTemplate, favorite, duplicate, moveTo, rename, addSubpage, openInNewTab, template, trash].compactMap { $0 }
    }
}

/// Меню строки из описателей: по местам, перед «Удалить в корзину» — линия.
@MainActor
public enum PageRowMenu {
    public static func make(items: [PageRowMenuItem], context: PageRowMenuContext,
                            handlers: [PageRowMenuSlot: (UUID) -> Void]) -> NSMenu {
        let menu = NSMenu()
        for item in items.sorted(by: { $0.slot < $1.slot }) {
            guard let title = item.title(context), let handler = handlers[item.slot] else { continue }
            if item.slot == .trash, !menu.items.isEmpty { menu.addItem(.separator()) }
            let pageId = context.pageId
            menu.addItem(PageMenuItem(title: title) { handler(pageId) })
        }
        return menu
    }
}
