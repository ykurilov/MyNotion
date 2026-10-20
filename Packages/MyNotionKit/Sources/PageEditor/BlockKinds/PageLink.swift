import NotesCore

extension BlockKindDescriptor {
    /// Подстраница: в меню «/» — «Страница», как «Page» у Notion 7.39 (сразу за переключателем, значок — лист, как в дереве).
    /// Выбор не меняет тип блока сам: подстраницу со ссылкой создаёт владелец дерева (`PageTextView.onSubpageRequest`).
    /// Текста у блока нет: строку рисует фрагмент.
    static let pageLink = BlockKindDescriptor(
        kind: .pageLink,
        menuItem: PopupMenuItem(title: "Страница", icon: .document, keywords: ["page", "страница", "подстраница", "subpage"],
                                action: .setKind(.pageLink)),
        marker: .pageLink
    )
}
