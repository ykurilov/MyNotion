import AppKit
import NotesCore

extension PageTextView {
    /// «/» → «Таблица»: 3 столбца × 2 строки; пустой абзац сам становится таблицей, у абзаца с текстом таблица — ниже.
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
        changes.upserts += [table] + TableGrid.contents(ofNewTable: table, columns: 3, rows: 2)
        // Под таблицей в конце потока — пустой абзац: писать дальше есть где.
        if index + 1 == blocks.count {
            changes.upserts.append(Block(pageId: document.pageId, sortKey: .between(key, nil), containerId: document.containerId))
        }
        applyStructuralChanges(changes, actionName: "Таблица")
        textLayoutManager?.textViewportLayoutController.layoutViewport()
        blockViews.update()
        tableView(for: table.id)?.activate(TableCellPosition(row: 0, column: 0), caret: .start)
    }
}
