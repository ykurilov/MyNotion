import Foundation
import NotesCore

/// Подписчик записи (research R11): отмечает страницы, чьё содержимое изменилось, — своя правка или пачка с другого Mac
/// (автор — тот Mac), — в `page_version_due` той же транзакцией. У строки базы содержимое — и значения свойств со связями
/// (research R15); смена типа свойства и новое свойство версий строк не порождают (их отменяет ⌘Z). Избранное, открытие,
/// место в дереве и корзина версий не порождают. Страница, стёртая навсегда, теряет версии и отметку вместе с собой.
struct PageVersionDueMarker: NotesWriteHook {
    /// Поля страницы, которые входят в снимок.
    static let versionedFields: Set<Page.Field> = [.title, .icon, .cover, .isFullWidth, .isSmallText]

    let localDeviceName: String
    let now: @Sendable () -> Date
    /// После фиксации: есть новые отметки.
    let onMarked: @Sendable () -> Void

    func notesWillCommit(_ changes: NotesChanges, in transaction: NotesTransaction) throws {
        let erased = Set(changes.erasedPageIds)
        var marked: Set<UUID> = []
        for change in changes.pages where !change.changedFields.isDisjoint(with: Self.versionedFields) {
            marked.insert(change.page.id)
        }
        for change in changes.blocks {
            switch change {
            case .saved(let block, _, _): marked.insert(block.pageId)
            case .erased(_, let pageId): marked.insert(pageId)
            }
        }
        let schemaEdits = changes.database.bulkCellProperties.union(changes.database.properties.filter {
            $0.isNew || $0.changedFields.contains(.typeAndConfig)
        }.map(\.record.id))
        for cell in changes.database.cells where !schemaEdits.contains(cell.propertyId) { marked.insert(cell.rowId) }
        for change in changes.database.relationLinks where !schemaEdits.contains(change.record.propertyId) {
            marked.insert(change.record.rowId)
        }
        marked.subtract(erased)
        if !erased.isEmpty { try PageVersionStore.erase(pages: Array(erased), in: transaction.database) }
        guard !marked.isEmpty else { return }
        try PageVersionStore.markDue(marked, at: now(), deviceName: transaction.replicatedFromDeviceName ?? localDeviceName,
                                     in: transaction.database)
        transaction.afterCommit(onMarked)
    }
}
