import NotesCore
import VisualStyle

extension BlockKindDescriptor {
    /// Колонки (US6): в потоке — один знак-вложение с видом `ColumnsView`, у каждой колонки — свой поток блоков.
    /// В меню «/» — «Колонки: 2 / 3 / 4 / 5» (contracts/blocks-and-keys.md); «Превратить в» колонок нет.
    static let columnList: BlockKindDescriptor = {
        var descriptor = BlockKindDescriptor(
            kind: .columnList,
            topSpacing: Metrics.block(.paragraph).topSpacing,
            bottomSpacing: Metrics.block(.paragraph).topSpacing,
            gallerySamples: [
                BlockGallerySample(id: "columns-two", summary: "Две колонки: заголовок, абзацы и список; блоки над и под колонками",
                                   blocks: [
                                       .init(.paragraph, "Абзац над колонками во всю ширину страницы."),
                                       ColumnsSample.block([
                                           [.init(.heading3, "Левая колонка"), .init(.paragraph, "Текст левой колонки переносится по её ширине, а не по ширине страницы."),
                                            .init(.bulletItem, "Пункт"), .init(.bulletItem, "Вложенный", indent: 1)],
                                           [.init(.heading3, "Правая колонка"), .init(.paragraph, "Короткий текст."),
                                            .init(.checkbox, "Задача в колонке")],
                                       ]),
                                       .init(.paragraph, "Абзац под колонками."),
                                   ], narrowToo: true),
                BlockGallerySample(id: "columns-three-ratios", summary: "Три колонки разной ширины (20 / 50 / 30 %)",
                                   blocks: [
                                       ColumnsSample.block([
                                           [.init(.paragraph, "Узкая")],
                                           [.init(.paragraph, "Широкая колонка с длинным текстом, который занимает несколько строк.")],
                                           [.init(.callout, "Выноска")],
                                       ], ratios: [0.2, 0.5, 0.3]),
                                   ]),
            ],
            // Богатая страница (quickstart.md): 2 блока колонок по 3 колонки.
            richPageBlocks: (1...2).flatMap { number in
                [RichBlockSpec(.paragraph, "Перед колонками \(number)"),
                 RichBlockSpec(.columnList, contained: (1...3).map { column in
                     RichBlockSpec(.column, contained: (1...5).map { line in
                         RichBlockSpec(line == 1 ? .heading3 : .paragraph, "Колонка \(column), строка \(line) блока колонок \(number)")
                     })
                 })]
            }
        )
        descriptor.insertMenuItems = (2...ColumnLayout.maximumColumns).map { count in
            PopupMenuItem(title: "Колонки: \(count)", icon: .symbol("rectangle.split.\(min(count, 3))x1"),
                          keywords: ["columns \(count)", "колонки \(count)", "columns", "колонки"], action: .insertColumns(count))
        }
        return descriptor
    }()

    static let column = BlockKindDescriptor(kind: .column)
}

/// Колонки образцов галереи.
enum ColumnsSample {
    static func block(_ columns: [[BlockGallerySample.SampleBlock]], ratios: [Double] = []) -> BlockGallerySample.SampleBlock {
        BlockGallerySample.SampleBlock(.columnList, contained: columns.enumerated().map { index, blocks in
            var props = BlockProps()
            if index < ratios.count { props.widthRatio = ratios[index] }
            return BlockGallerySample.SampleBlock(.column, props: props, contained: blocks)
        })
    }
}
