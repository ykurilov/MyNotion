import NotesCore
import VisualStyle

extension BlockKindDescriptor {
    /// Раскрывающийся список (US1): треугольник ▸/▾ в колонке маркера, дети — следующие блоки глубже (research R1).
    static let toggle = BlockKindDescriptor(
        kind: .toggle,
        menuItem: PopupMenuItem(title: "Раскрывающийся список", icon: .symbol("arrowtriangle.right.fill"),
                                keywords: ["переключатель", "toggle", "список", "раскрывающийся", ">"], action: .setKind(.toggle)),
        markdownShortcuts: [">"],
        textStyle: .listItem,
        marker: .painted,
        emptyHint: "Раскрывающийся список",
        exitsOnEmptyEnter: true,
        continuesAfterSplit: true,
        painters: [TogglePainter()],
        gallerySamples: [
            BlockGallerySample(id: "structural-toggle", summary: "Переключатели: раскрытый с детьми, свёрнутый, пустой, вложенный, заголовок внутри",
                               blocks: [
                                   .init(.toggle, "Раскрытый переключатель"),
                                   .init(.paragraph, "Ребёнок — обычный абзац", indent: 1),
                                   .init(.heading3, "Заголовок внутри", indent: 1),
                                   .init(.toggle, "Вложенный свёрнутый", indent: 1, isCollapsed: true),
                                   .init(.paragraph, "Скрытый текст", indent: 2),
                                   .init(.toggle, "Свёрнутый переключатель", isCollapsed: true),
                                   .init(.paragraph, "Не видно", indent: 1),
                                   .init(.toggle),
                                   .init(.paragraph, "Абзац после"),
                               ], narrowToo: true),
        ],
        // Богатая страница (quickstart.md): 20 переключателей, 5 свёрнуты, в одном 200 детей.
        richPageBlocks: [RichBlockSpec(.toggle, "Свёрнутый переключатель с 200 детьми", isCollapsed: true)]
            + (1...200).map { RichBlockSpec(.paragraph, "Скрытый ребёнок \($0)", indent: 1) }
            + (1...19).flatMap { number in
                [RichBlockSpec(.toggle, "Переключатель \(number)", isCollapsed: number <= 4),
                 RichBlockSpec(.paragraph, "Ребёнок переключателя \(number)", indent: 1)]
            }
    )
}
