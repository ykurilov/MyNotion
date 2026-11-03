import AppKit
import VisualStyle

/// Пункты страницы в меню блока-ссылки на страницу (правая кнопка в редакторе), как у Notion 7.39: те же описатели
/// и обработчики окна, что у меню строки панели, — действуют на страницу по ссылке. Группы через черту, подвал — серым.
@MainActor
public enum PageLinkMenu {
    /// Места по группам, сверху вниз.
    static let groups: [[PageRowMenuItem?]] = [
        [.changeIcon, PageRowMenuItem.favorite, PageRowMenuItem.rename],
        [PageRowMenuItem.openInNewTab, .openInNewWindow],
        [PageRowMenuItem.copyLink, PageRowMenuItem.duplicate, PageRowMenuItem.moveTo, PageRowMenuItem.trash],
        [.askAI],
    ]

    /// Пункты для страницы `context`; пункт без обработчика окна не показывается, пустая группа места не занимает.
    /// `footer` — «Изменено: …, N слов» под чертой.
    public static func entries(context: PageRowMenuContext, handlers: [PageRowMenuSlot: (UUID) -> Void],
                               footer: String?) -> [ActionMenuEntry] {
        var entries: [ActionMenuEntry] = []
        for group in groups {
            let actions = group.compactMap { $0 }.compactMap {
                PageRowMenu.action($0, context: context, handlers: handlers, identifierPrefix: "page-link-menu")
            }
            guard !actions.isEmpty else { continue }
            if !entries.isEmpty { entries.append(.separator) }
            entries += actions.map(ActionMenuEntry.action)
        }
        if let footer {
            if !entries.isEmpty { entries.append(.separator) }
            entries.append(.footer(footer, identifier: "page-link-menu-footer"))
        }
        return entries
    }
}
