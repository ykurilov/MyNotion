import NotesCore
import VisualStyle

extension BlockKindDescriptor {
    /// Выноска (US1): подложка во всю ширину от первой строки до последнего ребёнка, иконка-эмодзи слева от текста.
    static let callout = BlockKindDescriptor(
        kind: .callout,
        menuItem: PopupMenuItem(title: "Выноска", icon: .symbol("exclamationmark.bubble"), keywords: ["callout", "выноска", "заметка"],
                                action: .setKind(.callout)),
        textStyle: .paragraph,
        leadingInset: Metrics.Callout.textInset,
        // Поле снизу — у последнего видимого блока выноски (`CollapsedParagraphs.extraSpacing`): у самой выноски или её ребёнка.
        topSpacing: Metrics.Callout.outerSpacing + Metrics.Callout.verticalPadding,
        emptyHint: "Введите текст…",
        gallerySamples: [
            BlockGallerySample(id: "structural-callout", summary: "Выноска по умолчанию, с детьми, другая иконка, пустая",
                               blocks: [
                                   .init(.callout, "Выноска по умолчанию: серый фон и 💡", color: .defaults(for: .callout)),
                                   .init(.paragraph, "Абзац между"),
                                   .init(.callout, "Выноска с детьми", color: .defaults(for: .callout),
                                         props: BlockProps(["icon": .string("🚀")])),
                                   .init(.paragraph, "ребёнок-абзац", indent: 1),
                                   .init(.checkbox, "ребёнок-чекбокс", indent: 1),
                                   .init(.callout, color: BlockColor(background: .blue)),
                                   .init(.callout, "Выноска без цвета — рамка"),
                                   .init(.paragraph, "Абзац после"),
                               ], narrowToo: true),
        ],
        // Богатая страница (quickstart.md): 10 выносок, у половины — ребёнок.
        richPageBlocks: (1...10).flatMap { number in
            [RichBlockSpec(.callout, "Выноска \(number): совет для замера")]
                + (number.isMultiple(of: 2) ? [RichBlockSpec(.paragraph, "Внутри выноски \(number)", indent: 1)] : [])
        }
    )
}
