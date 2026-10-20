import NotesCore
import VisualStyle

extension BlockKindDescriptor {
    /// Цитата (US1): черта слева во всю высоту цитаты и её детей, шрифт как у абзаца.
    static let quote = BlockKindDescriptor(
        kind: .quote,
        menuItem: PopupMenuItem(title: "Цитата", icon: .symbol("text.quote"), keywords: ["quote", "цитата", "\""],
                                action: .setKind(.quote)),
        markdownShortcuts: ["\""],
        textStyle: .paragraph,
        leadingInset: Metrics.Quote.textInset,
        emptyHint: "Пустая цитата",
        gallerySamples: [
            BlockGallerySample(id: "structural-quote", summary: "Цитата в две строки, цитата с детьми, пустая",
                               blocks: [
                                   .init(.quote, "Простота — необходимое условие красоты.\nЛев Толстой"),
                                   .init(.paragraph, "Абзац между"),
                                   .init(.quote, "Цитата с вложенными"),
                                   .init(.paragraph, "ребёнок-абзац", indent: 1),
                                   .init(.bulletItem, "ребёнок-пункт", indent: 1),
                                   .init(.quote),
                               ], narrowToo: true),
        ],
        // Богатая страница (quickstart.md): 10 цитат, у половины — ребёнок.
        richPageBlocks: (1...10).flatMap { number in
            [RichBlockSpec(.quote, "Цитата \(number): короткая мысль для замера")]
                + (number.isMultiple(of: 2) ? [RichBlockSpec(.paragraph, "Внутри цитаты \(number)", indent: 1)] : [])
        }
    )
}
