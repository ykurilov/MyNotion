import NotesCore
import VisualStyle

extension BlockKindDescriptor {
    static let heading1 = heading(.heading1, level: 1, label: "H₁", style: .heading1)
    static let heading2 = heading(.heading2, level: 2, label: "H₂", style: .heading2)
    static let heading3 = heading(.heading3, level: 3, label: "H₃", style: .heading3)

    /// Свёрнутые заголовки: H2 прячет абзацы и H3 до следующего H2; пустой раздел — без подписи.
    private static let foldSamples = [
        BlockGallerySample(id: "structural-heading-fold", summary: "Заголовки: свёрнутый H2 с подписью, раскрытый, свёрнутый без раздела",
                           blocks: [
                               .init(.heading2, "Свёрнутый раздел", isCollapsed: true),
                               .init(.paragraph, "Скрытый абзац"),
                               .init(.heading3, "Скрытый подзаголовок"),
                               .init(.paragraph, "Ещё скрытый абзац"),
                               .init(.heading2, "Раскрытый раздел"),
                               .init(.paragraph, "Видимый абзац под заголовком"),
                               .init(.heading3, "Свёрнутый подраздел", isCollapsed: true),
                               .init(.paragraph, "Скрытый"),
                               .init(.heading1, "Свёрнутый пустой", isCollapsed: true),
                           ], narrowToo: true),
    ]

    private static func heading(_ kind: BlockKind, level: Int, label: String, style: BlockTextStyle) -> BlockKindDescriptor {
        let hashes = String(repeating: "#", count: level)
        return BlockKindDescriptor(
            kind: kind,
            menuItem: PopupMenuItem(title: "Заголовок \(level)", icon: .label(label), keywords: ["h\(level)", "heading", hashes],
                                    action: .setKind(kind), hint: "⌥⌘\(level)"),
            markdownShortcuts: [hashes],
            textStyle: style,
            emptyHint: "Заголовок \(level)",
            painters: [HeadingFoldPainter()],
            gallerySamples: level == 2 ? foldSamples : []
        )
    }
}
