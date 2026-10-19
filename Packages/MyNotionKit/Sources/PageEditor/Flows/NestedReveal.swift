import AppKit
import NotesCore

extension PageTextView {
    /// Перейти к блоку колонки или ячейке таблицы (поиск страниц, ⌘F): показать вид колонок или таблицы,
    /// поставить курсор в редактор колонки или поле правки ячейки (research R4).
    func revealNestedBlock(_ id: UUID) {
        let pageDocument = document.pageDocument
        guard let block = pageDocument.block(id), scrollToNestedBlock(id) != nil else { return }
        switch block.kind {
        case .tableCell, .tableRow, .tableColumn:
            guard let tableId = ([id] + pageDocument.containerChain(of: block)).first(where: { pageDocument.block($0)?.kind == .table }),
                  let grid = pageDocument.tableGrid(tableId), let view = tableView(for: tableId) else { return }
            let position = grid.position(ofCell: id).map { TableCellPosition(row: $0.row, column: $0.column) }
                ?? TableCellPosition(row: max(0, grid.rows.firstIndex { $0.id == id } ?? 0), column: max(0, grid.columns.firstIndex { $0.id == id } ?? 0))
            view.activate(position, caret: .start)
        default:
            pageEditor.editorTree.first { $0 !== self && $0.document.index(ofBlock: id) != nil }?.revealBlock(id)
        }
    }

    /// Прокрутить к виду колонок или таблицы, внутри которых блок, и поставить вид на место — и так вглубь
    /// (таблица в колонке). Возвращает блок этого потока, внутри которого лежит `id`; блока нет — `nil`.
    @discardableResult
    func scrollToNestedBlock(_ id: UUID) -> UUID? {
        let pageDocument = document.pageDocument
        guard let block = pageDocument.block(id) else { return nil }
        let chain = [id] + pageDocument.containerChain(of: block)
        guard let top = chain.first(where: { document.index(ofBlock: $0) != nil }), let index = document.index(ofBlock: top) else { return nil }
        expandAncestors(ofBlockAt: index)
        let start = mapper.paragraphStart(ofBlockAt: index)
        scrollRangeToVisible(NSRange(location: start, length: 0))
        textLayoutManager?.textViewportLayoutController.layoutViewport()
        layoutEmbeddedViews()
        // Глубже: таблица или блок внутри колонки — в редакторе этой колонки.
        if top != id, let inner = embeddedFlowEditors.first(where: { editor in chain.contains { editor.document.index(ofBlock: $0) != nil } }) {
            inner.scrollToNestedBlock(id)
        }
        return top
    }
}
