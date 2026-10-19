import NotesCore
import VisualStyle

extension BlockKindDescriptor {
    static let bulletItem = BlockKindDescriptor(
        kind: .bulletItem,
        menuItem: PopupMenuItem(title: "Маркированный список", icon: .symbol("list.bullet"),
                                keywords: ["bullet", "list", "ul", "-", "пункт"], action: .setKind(.bulletItem)),
        markdownShortcuts: ["-", "*"],
        textStyle: .listItem,
        marker: .bullet,
        emptyHint: "Список",
        exitsOnEmptyEnter: true,
        continuesAfterSplit: true
    )
}
