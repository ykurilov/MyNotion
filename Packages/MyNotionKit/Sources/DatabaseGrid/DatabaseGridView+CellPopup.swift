import AppKit
import Databases
import NotesCore

/// Окно правки ячейки под ней (contracts/database-ui.md, «Ячейки и клавиши»): щелчок, Enter или первая буква по
/// выбранной ячейке выбора, статуса, даты, файлов (US2) и связи (US4). Закрылось — клавиши снова у сетки.
extension DatabaseGridView {
    func openCellPopup(replacingWith text: String?) {
        guard let controller, let position = selection?.focus, let column = content.columns[safe: position.column],
              let rowId = content.rowId(at: position.row), let factory = CellPopups.factory(for: column.property.kind) else { return }
        let context = CellPopupContext(controller: controller, rowId: rowId, propertyId: column.property.id, initialText: text)
        let host = CellPopupHost.shared
        context.close = { host.close() }
        context.resize = { host.resize() }
        let popup = factory.make(context)
        reveal(position)
        host.onClose = { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self.documentView)
            self.documentView.setNeedsDisplay(rows: position.row..<position.row + 1)
        }
        // Место — после прокрутки к ячейке (сетка и страница-база могли сдвинуться).
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            host.show(popup, below: self.documentView.cellRect(row: position.row, column: position.column), of: self.documentView)
        }
    }
}
