import AppKit
import NotesCore
import VisualStyle

extension PageTextView {
    /// «/» → «Таблица», как у Notion 7.39: 2 столбца × 3 строки во всю ширину колонки текста (240 и остаток);
    /// пустой абзац сам становится таблицей, у абзаца с текстом таблица — ниже.
    func insertTable(at index: Int) {
        commitEdits()
        let blocks = document.blocks
        guard blocks.indices.contains(index) else { return }
        let block = blocks[index]
        var changes = BlockChanges()
        let key: FractionalSortKey
        if block.text.string.isEmpty, block.kind == .paragraph {
            key = block.sortKey
            changes.removals.append(block.id)
        } else {
            key = .between(block.sortKey, blocks[safe: index + 1]?.sortKey)
        }
        let table = Block(pageId: document.pageId, kind: .table, indent: block.indent, sortKey: key, containerId: document.containerId,
                          props: .defaults(for: .table))
        changes.upserts += [table] + TableGrid.contents(ofNewTable: table, columns: 2, rows: 3,
                                                                     widths: TableGrid.columnWidths(ofNewTableFitting: availableTableWidth(indent: block.indent)))
        // Под таблицей в конце потока — пустой абзац: писать дальше есть где.
        if index + 1 == blocks.count {
            changes.upserts.append(Block(pageId: document.pageId, sortKey: .between(key, nil), containerId: document.containerId))
        }
        applyStructuralChanges(changes, actionName: "Таблица")
        textLayoutManager?.textViewportLayoutController.layoutViewport()
        blockViews.update()
        tableView(for: table.id)?.activate(TableCellPosition(row: 0, column: 0), caret: .start)
    }

    /// Ширина колонки текста под блоком с отступом `indent`: без полей строки и вложенности.
    private func availableTableWidth(indent: Int) -> Double {
        let container = textContainer.map { $0.size.width - 2 * $0.lineFragmentPadding } ?? Metrics.Page.columnWidth
        return Double((container - CGFloat(indent) * Metrics.Page.indentPerLevel).rounded(.down))
    }
}
