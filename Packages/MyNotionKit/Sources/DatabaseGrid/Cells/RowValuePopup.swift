import AppKit
import Databases
import NotesCore

/// Окно правки значения на странице строки (выбор, статус, дата, файлы, связь): то же окно, что у ячейки таблицы,
/// под значением. Нужно и шаблону строки (US6): его страница — единственное место, где правят его значения.
@MainActor
public enum RowValuePopup {
    /// `false` — у свойства нет окна правки или строки больше нет.
    @discardableResult
    public static func show(rowId: UUID, propertyId: UUID, store: NotesStore, operations: DatabaseOperations, below anchor: NSView) -> Bool {
        guard let databaseId = ((try? store.write { try $0.page(rowId)?.parentId }) ?? nil),
              let property = ((try? store.write { try $0.property(propertyId) }) ?? nil),
              let factory = CellPopups.factory(for: property.kind),
              let controller = DatabaseTableController(store: store, operations: operations, databaseId: databaseId) else { return false }
        let context = CellPopupContext(controller: controller, rowId: rowId, propertyId: propertyId, initialText: nil)
        let host = CellPopupHost.shared
        context.close = { host.close() }
        context.resize = { host.resize() }
        host.onClose = nil
        host.show(factory.make(context), below: anchor.bounds, of: anchor)
        return true
    }

    /// Закрыть окно правки значения, если оно открыто.
    public static func close() { CellPopupHost.shared.close() }
}
