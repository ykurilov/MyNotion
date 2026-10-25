import NotesCore
import VisualStyle

extension BlockKindDescriptor {
    static let paragraph = BlockKindDescriptor(
        kind: .paragraph,
        menuItem: PopupMenuItem(title: "Текст", icon: .label("T"), keywords: ["text", "paragraph", "абзац", "текст"],
                                action: .setKind(.paragraph), hint: "⌥⌘0"),
        textStyle: .paragraph,
        emptyHint: "Введите «/» для выбора блока",
        continuesAfterSplit: true
    )
}
