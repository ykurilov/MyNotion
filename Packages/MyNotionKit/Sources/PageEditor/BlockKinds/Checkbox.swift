import NotesCore
import VisualStyle

extension BlockKindDescriptor {
    static let checkbox = BlockKindDescriptor(
        kind: .checkbox,
        menuItem: PopupMenuItem(title: "Чекбокс", icon: .checkbox,
                                keywords: ["todo", "to-do", "checkbox", "task", "[]", "дело", "задача"], action: .setKind(.checkbox)),
        markdownShortcuts: ["[]", "[ ]"],
        textStyle: .listItem,
        marker: .checkbox,
        emptyHint: "Задача",
        exitsOnEmptyEnter: true,
        continuesAfterSplit: true
    )
}
