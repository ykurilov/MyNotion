import AppKit
import NotesCore
import VisualStyle

/// Место пункта в меню строки страницы панели (contracts/pages-ui.md, «Боковая панель»), по порядку.
public enum PageRowMenuSlot: Int, CaseIterable, Comparable, Sendable {
    case newFromTemplate, favorite, copyLink, duplicate, moveTo, rename, addSubpage, openInNewTab, template, trash
    /// Только в меню ссылки на страницу (`PageLinkMenu`).
    case changeIcon, openInNewWindow, askAI

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
        [newFromTemplate, favorite, copyLink, duplicate, moveTo, rename, addSubpage, openInNewTab, template, trash].compactMap { $0 }
    }
}

/// Меню строки из описателей — меню действий (`ActionMenuView`) в карточке, как меню «•••» страницы: по местам,
/// перед «Удалить в корзину» — черта; значки и подсказки клавиш — как у того же меню Notion 7.39.
@MainActor
public enum PageRowMenu {
    public static func entries(items: [PageRowMenuItem], context: PageRowMenuContext,
                               handlers: [PageRowMenuSlot: (UUID) -> Void]) -> [ActionMenuEntry] {
        var entries: [ActionMenuEntry] = []
        for item in items.sorted(by: { $0.slot < $1.slot }) {
            guard let action = action(item, context: context, handlers: handlers, identifierPrefix: "row-menu") else { continue }
            if item.slot == .trash, !entries.isEmpty { entries.append(.separator) }
            entries.append(.action(action))
        }
        return entries
    }

    /// Пункт для страницы `context`: название, значок и подсказка места, обработчик окна; `nil` — пункт не нужен или обработчика нет.
    static func action(_ item: PageRowMenuItem, context: PageRowMenuContext, handlers: [PageRowMenuSlot: (UUID) -> Void],
                       identifierPrefix: String) -> ActionMenuAction? {
        guard let title = item.title(context), let handler = handlers[item.slot] else { return nil }
        let pageId = context.pageId
        return ActionMenuAction(title: title, icon: item.slot.icon(context), hint: item.slot.hint,
                                identifier: "\(identifierPrefix)-\(item.slot)") { _ in handler(pageId) }
    }

    public static func make(items: [PageRowMenuItem], context: PageRowMenuContext,
                            handlers: [PageRowMenuSlot: (UUID) -> Void]) -> ActionMenuView {
        ActionMenuView(entries: entries(items: items, context: context, handlers: handlers), width: Metrics.ActionMenu.rowMenuWidth)
    }
}

extension PageRowMenuSlot {
    /// Значок пункта (SF Symbols) — близкий к значку того же пункта у Notion 7.39.
    func icon(_ context: PageRowMenuContext) -> String {
        switch self {
        case .newFromTemplate: "doc.badge.plus"
        case .favorite: context.isFavorite ? "star.slash" : "star"
        case .copyLink: "link"
        case .duplicate: "square.on.square"
        case .moveTo: "arrow.turn.up.right"
        case .rename: "square.and.pencil"
        case .addSubpage: "plus"
        case .openInNewTab: "macwindow.badge.plus"
        case .template: "doc.on.doc"
        case .trash: "trash"
        case .changeIcon: "face.smiling"
        case .openInNewWindow: "macwindow"
        case .askAI: "sparkles"
        }
    }

    /// Подсказка клавиш справа — те же, что у пунктов меню «•••» страницы.
    var hint: String? {
        switch self {
        case .copyLink: "⌘L"
        case .duplicate: "⌘D"
        case .moveTo: "⌘⇧P"
        default: nil
        }
    }
}

/// Меню строки в карточке (`PopupCard`): от середины «⋯» или от точки щелчка правой кнопкой.
@MainActor
final class PageRowMenuPresenter {
    private let card = PopupCard()
    private var menu: ActionMenuView?

    var isShown: Bool { card.isShown }

    /// Показать `menu` от середины кнопки `button` (как у Notion) или от точки `point` вида `view`.
    func show(_ menu: ActionMenuView, from point: NSPoint, in view: NSView) {
        self.menu = menu
        menu.onChoose = { [weak self] in self?.card.close() }
        card.show(menu, size: menu.fittingSize, from: view.convert(point, to: nil), in: view)
    }

    func show(_ menu: ActionMenuView, from button: NSView) {
        show(menu, from: NSPoint(x: button.bounds.midX, y: button.bounds.midY), in: button)
    }

    func close() { card.close() }
}
