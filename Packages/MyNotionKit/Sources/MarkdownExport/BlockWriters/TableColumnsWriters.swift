import Foundation
import NotesCore

/// Таблица и колонки в Markdown (contracts/markdown-and-notion.md, «Блоки»).

/// Таблица GFM: первая строка — шапка всегда (так требует GFM). Без строки заголовков, со столбцом заголовков
/// или с шириной столбцов не по умолчанию — перед таблицей пометка `<!-- mynotion:table … -->`.
/// В ячейке `|` экранируется, перенос — `<br>`.
struct TableWriter: MarkdownBlockKindWriter {
    var kinds: Set<BlockKind> { [.table] }

    func lines(for block: Block, children: [String], context: MarkdownWriteContext) -> [String]? {
        let grid = TableGrid(table: block, flow: context.flow)
        guard grid.columnCount > 0, grid.rowCount > 0 else { return nil }
        let widths = grid.columns.indices.map { grid.width(ofColumn: $0) }
        var lines: [String] = []
        if !grid.hasHeaderRow || grid.hasHeaderColumn || widths.contains(where: { $0 != TableGrid.defaultColumnWidth }) {
            var comment = "<!-- mynotion:table header-row=\"\(grid.hasHeaderRow)\" header-column=\"\(grid.hasHeaderColumn)\""
            if widths.contains(where: { $0 != TableGrid.defaultColumnWidth }) {
                comment += " widths=\"" + widths.map { String(format: "%g", $0) }.joined(separator: ",") + "\""
            }
            lines.append(comment + " -->")
        }
        func row(_ index: Int) -> String {
            let cells = (0..<grid.columnCount).map { column in
                InlineMarkdown.render(grid.text(row: index, column: column), resolveLink: context.resolveLink)
                    .replacingOccurrences(of: "|", with: "\\|")
                    .replacingOccurrences(of: "\n", with: "<br>")
            }
            return "| " + cells.joined(separator: " | ") + " |"
        }
        lines.append(row(0))
        lines.append("| " + Array(repeating: "---", count: grid.columnCount).joined(separator: " | ") + " |")
        lines += (1..<grid.rowCount).map(row)
        return lines
    }
}

/// `<div data-columns>`, на колонку `<div data-column data-width="0.5">`, пустая строка, блоки Markdown, пустая строка,
/// `</div>`, … `</div>`.
struct ColumnsWriter: MarkdownBlockKindWriter {
    var kinds: Set<BlockKind> { [.columnList] }

    func lines(for block: Block, children: [String], context: MarkdownWriteContext) -> [String]? {
        let columns = context.flow(block.id).filter { $0.kind == .column }
        guard !columns.isEmpty else { return nil }
        var lines = ["<div data-columns>"]
        for (column, ratio) in zip(columns, ColumnLayout.ratios(of: columns)) {
            lines.append("<div data-column data-width=\"\(String(format: "%g", ratio))\">")
            let markdown = context.render(context.flow(column.id))
            lines.append("")
            if !markdown.isEmpty { lines += markdown.components(separatedBy: "\n").dropLast() + [""] }
            lines.append("</div>")
        }
        return lines + ["</div>"]
    }
}
