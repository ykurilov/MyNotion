import Foundation
import NotesCore
import VisualStyle

extension BlockKindDescriptor {
    /// Простая таблица (US6): в потоке — один знак-вложение с видом `TableView`; столбцы, строки и ячейки — в её потоках.
    /// В меню «/» — «Таблица» (2 столбца × 3 строки во всю ширину, как у Notion 7.39); «Превратить в» таблицы нет.
    static let table: BlockKindDescriptor = {
        var descriptor = BlockKindDescriptor(
            kind: .table,
            topSpacing: Metrics.Table.verticalMargin,
            bottomSpacing: Metrics.Table.verticalMargin,
            gallerySamples: [
                BlockGallerySample(id: "table-header-row", summary: "Таблица 3 × 3 со строкой заголовков, оформлением и переносом в ячейке",
                                   blocks: [
                                       .init(.paragraph, "Абзац над таблицей"),
                                       TableSample.block([["Имя", "Роль", "Город"],
                                                          ["Юрий", "Автор, **ведёт** проект", "Бали"],
                                                          ["Мишка", "Тестировщик\nпо выходным", ""]], headerRow: true),
                                       .init(.paragraph, "Абзац под таблицей"),
                                   ], narrowToo: true),
                BlockGallerySample(id: "table-new", summary: "Таблица из «/», как у Notion 7.39: 2 столбца × 3 строки во всю ширину",
                                   blocks: [
                                       .init(.paragraph, "Абзац над таблицей"),
                                       TableSample.block([["Задача", "Заметка"], ["Сверить с Notion", "Таблица во всю ширину страницы"], ["", ""]],
                                                         widths: TableGrid.columnWidths(ofNewTableFitting: 716)),
                                       .init(.paragraph, "Абзац под таблицей"),
                                   ]),
                BlockGallerySample(id: "table-header-column", summary: "Таблица со строкой и столбцом заголовков, широкий столбец",
                                   blocks: [
                                       TableSample.block([["", "Пн", "Вт"], ["Утро", "Йога", "Бег"], ["Вечер", "Чтение", ""]],
                                                         headerRow: true, headerColumn: true, widths: [120, 200, 120]),
                                   ]),
            ],
            // Богатая страница (quickstart.md): 3 таблицы 5 × 5.
            richPageBlocks: (1...3).flatMap { number in
                [RichBlockSpec(.paragraph, "Перед таблицей \(number)"),
                 TableSample.rich((0..<5).map { row in (0..<5).map { column in "Ячейка \(row + 1).\(column + 1) таблицы \(number)" } })]
            }
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

/// Таблицы образцов галереи и богатой страницы: столбцы, строки и ячейки с id столбца.
enum TableSample {
    /// «**текст**» в ячейке — жирный.
    private static func text(_ source: String) -> InlineText {
        guard let open = source.range(of: "**"), let close = source.range(of: "**", range: open.upperBound..<source.endIndex) else {
            return InlineText(source)
        }
        let before = String(source[..<open.lowerBound]), bold = String(source[open.upperBound..<close.lowerBound])
        let string = before + bold + String(source[close.upperBound...])
        return InlineText(string, runs: [StyledRun(start: (before as NSString).length, length: (bold as NSString).length, style: .bold)])
    }

    static func block(_ cells: [[String]], headerRow: Bool = false, headerColumn: Bool = false,
                      widths: [Double] = []) -> BlockGallerySample.SampleBlock {
        var props = BlockProps.defaults(for: .table)
        props.hasHeaderRow = headerRow
        props.hasHeaderColumn = headerColumn
        let columnCount = cells.map(\.count).max() ?? 0
        let columns = (0..<columnCount).map { index in
            var columnProps = BlockProps.defaults(for: .tableColumn)
            if index < widths.count { columnProps.width = widths[index] }
            return BlockGallerySample.SampleBlock(.tableColumn, props: columnProps)
        }
        let rows = cells.map { row in
            BlockGallerySample.SampleBlock(.tableRow, contained: row.enumerated().compactMap { index, source in
                guard !source.isEmpty else { return nil }
                var cellProps = BlockProps()
                cellProps.columnId = columns[index].id
                var cell = BlockGallerySample.SampleBlock(.tableCell, props: cellProps)
                cell.text = text(source)
                return cell
            })
        }
        return BlockGallerySample.SampleBlock(.table, props: props, contained: columns + rows)
    }

    static func rich(_ cells: [[String]]) -> RichBlockSpec {
        var props = BlockProps.defaults(for: .table)
        props.hasHeaderRow = true
        let columns = (0..<(cells.first?.count ?? 0)).map { _ in RichBlockSpec(.tableColumn) }
        let rows = cells.map { row in
            RichBlockSpec(.tableRow, contained: row.enumerated().map { index, text in
                var cellProps = BlockProps()
                cellProps.columnId = columns[index].id
                return RichBlockSpec(.tableCell, text, props: cellProps)
            })
        }
        return RichBlockSpec(.table, props: props, contained: columns + rows)
    }
}
