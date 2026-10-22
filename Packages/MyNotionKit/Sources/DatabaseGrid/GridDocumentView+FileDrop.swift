import AppKit
import Databases
import NotesCore
import VisualStyle

/// Файлы из Finder прямо на ячейку «Файлы и медиа» (spec US2, сценарий 5): ячейка под курсором подсвечивается рамкой,
/// отпускание копирует файлы и добавляет их в конец ячейки одной правкой. Файл больше 100 МБ — сообщение, как в 002.
extension GridDocumentView {
    /// Ячейка файлов под точкой (координаты вида).
    func filesDropTarget(at point: NSPoint) -> CellPosition? {
        guard grid?.controller != nil, let position = position(at: point), content.columns[safe: position.column]?.property.kind == .files else {
            return nil
        }
        return position
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let target = filesDropTarget(at: convert(sender.draggingLocation, from: nil))
        if let target { grid?.select(target) }
        return target == nil ? [] : .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let target = filesDropTarget(at: convert(sender.draggingLocation, from: nil)), let controller = grid?.controller,
              let rowId = content.rowId(at: target.row), let property = content.columns[safe: target.column]?.property else { return false }
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        let window = window
        FilesCellImport.run(urls, store: controller.store, operations: controller.operations, rowId: rowId, propertyId: property.id) { error in
            guard let error, let window else { return }
            let alert = NSAlert()
            alert.messageText = error
            alert.beginSheetModal(for: window)
        }
        return true
    }
}
