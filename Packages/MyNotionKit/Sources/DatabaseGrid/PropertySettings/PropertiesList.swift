import Databases
import Foundation
import NotesCore

/// Окно «Свойства» базы (contracts/database-ui.md, «Панель «Изменить свойство»»): свойства по порядку с ручками и
/// (сверх Notion, spec, Edge Cases) «Удалённые свойства» с «Вернуть» и «Удалить навсегда».
@MainActor
public struct PropertiesList {
    /// Неудалённые свойства по порядку базы.
    public let active: [DatabaseProperty]
    /// Удалённые, но не стёртые навсегда — новые сверху.
    public let deleted: [DatabaseProperty]

    public static func read(databaseId: UUID, store: NotesStore) throws -> PropertiesList {
        PropertiesList(active: try DatabaseCatalog.read(databaseId, in: store).properties,
                       deleted: try DatabaseCatalog.deletedProperties(of: databaseId, in: store))
    }

    /// Перестановка ручкой: свойство брошено в место вставки `insertionIndex` (0…число свойств) прежнего списка.
    public func move(_ propertyId: UUID, toInsertionIndex insertionIndex: Int, operations: DatabaseOperations) throws {
        guard let from = active.firstIndex(where: { $0.id == propertyId }) else { return }
        let target = insertionIndex > from ? insertionIndex - 1 : insertionIndex
        guard target != from else { return }
        try operations.moveProperty(propertyId, to: target)
    }

    /// Второго ID в базе не бывает: удалённое ID возвращается, только если другого нет.
    public func canRestore(_ property: DatabaseProperty) -> Bool {
        property.kind != .uniqueId || !active.contains { $0.kind == .uniqueId }
    }

    public func restore(_ property: DatabaseProperty, operations: DatabaseOperations) throws {
        guard canRestore(property) else { return }
        try operations.setDeleted(property.id, false)
    }

    /// «Удалить навсегда»: значения стираются (⌘Z возвращает).
    public func erase(_ property: DatabaseProperty, operations: DatabaseOperations) throws {
        try operations.eraseProperty(property.id)
    }
}
