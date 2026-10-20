import NotesCore
import VisualStyle

extension BlockKindDescriptor {
    static let heading1 = heading(.heading1, level: 1, label: "H₁", style: .heading1)
    static let heading2 = heading(.heading2, level: 2, label: "H₂", style: .heading2)
    static let heading3 = heading(.heading3, level: 3, label: "H₃", style: .heading3)

    private static func heading(_ kind: BlockKind, level: Int, label: String, style: BlockTextStyle) -> BlockKindDescriptor {
        let hashes = String(repeating: "#", count: level)
        return BlockKindDescriptor(
            kind: kind,
            menuItem: PopupMenuItem(title: "Заголовок \(level)", icon: .label(label), keywords: ["h\(level)", "heading", hashes],
                                    action: .setKind(kind)),
            markdownShortcuts: [hashes],
            textStyle: style,
            emptyHint: "Заголовок \(level)"
        )
    }
}
