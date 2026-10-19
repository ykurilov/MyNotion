import NotesCore
import VisualStyle

extension BlockKindDescriptor {
    static let numberedItem = BlockKindDescriptor(
        kind: .numberedItem,
        menuItem: PopupMenuItem(title: "Нумерованный список", icon: .symbol("list.number"),
                                keywords: ["numbered", "ordered", "list", "ol", "1.", "номер"], action: .setKind(.numberedItem)),
        markdownShortcuts: ["1."],
        textStyle: .listItem,
        marker: .number,
        emptyHint: "Список",
        exitsOnEmptyEnter: true,
        continuesAfterSplit: true
    )
}
