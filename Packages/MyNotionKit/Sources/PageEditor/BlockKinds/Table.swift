import NotesCore
import VisualStyle

extension BlockKindDescriptor {
    /// Простая таблица (US6): в потоке — один знак-вложение с видом `TableView`; столбцы, строки и ячейки — в её потоках.
    /// В меню «/» — «Таблица» (3 × 2); «Превратить в» таблицы нет.
    static let table: BlockKindDescriptor = {
        var descriptor = BlockKindDescriptor(
            kind: .table,
            topSpacing: Metrics.Table.verticalMargin,
            bottomSpacing: Metrics.Table.verticalMargin
        )
        descriptor.insertMenuItems = [
            PopupMenuItem(title: "Таблица", icon: .symbol("tablecells"), keywords: ["table", "таблица"], action: .insertTable),
        ]
        return descriptor
    }()

    static let tableRow = BlockKindDescriptor(kind: .tableRow)
    static let tableColumn = BlockKindDescriptor(kind: .tableColumn)
    /// Ячейка — текст шрифтом таблицы; правится полем правки ячейки (`TableCellEditor`).
    static let tableCell = BlockKindDescriptor(kind: .tableCell, textStyle: .tableCell, topSpacing: 0, bottomSpacing: 0)
}
