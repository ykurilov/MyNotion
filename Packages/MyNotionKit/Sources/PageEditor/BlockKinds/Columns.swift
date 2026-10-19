import NotesCore
import VisualStyle

extension BlockKindDescriptor {
    /// Колонки (US6): в потоке — один знак-вложение с видом `ColumnsView`, у каждой колонки — свой поток блоков.
    /// В меню «/» — «Колонки: 2 / 3 / 4 / 5» (contracts/blocks-and-keys.md); «Превратить в» колонок нет.
    static let columnList: BlockKindDescriptor = {
        var descriptor = BlockKindDescriptor(
            kind: .columnList,
            topSpacing: Metrics.block(.paragraph).topSpacing,
            bottomSpacing: Metrics.block(.paragraph).topSpacing
        )
        descriptor.insertMenuItems = (2...ColumnLayout.maximumColumns).map { count in
            PopupMenuItem(title: "Колонки: \(count)", icon: .symbol("rectangle.split.\(min(count, 3))x1"),
                          keywords: ["columns \(count)", "колонки \(count)", "columns", "колонки"], action: .insertColumns(count))
        }
        return descriptor
    }()

    static let column = BlockKindDescriptor(kind: .column)
}
