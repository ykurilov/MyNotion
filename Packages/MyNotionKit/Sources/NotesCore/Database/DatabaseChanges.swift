import Foundation

/// Запись базы с метками полей: база, свойство, вариант, вид, связь.
public protocol ClockedDatabaseRecord: Sendable, Hashable {
    associatedtype Field: RawRepresentable & Hashable & CaseIterable & Sendable where Field.RawValue == String
    var fieldClocks: RecordClocks<Field> { get set }
    func changedFields(comparedTo old: Self) -> Set<Field>
}

extension DatabaseSchema: ClockedDatabaseRecord {}
extension DatabaseProperty: ClockedDatabaseRecord {}
extension SelectOption: ClockedDatabaseRecord {}
extension DatabaseView: ClockedDatabaseRecord {}
extension RelationLink: ClockedDatabaseRecord {}

/// Записанная запись базы и её изменённые поля.
public struct RecordChange<Record: ClockedDatabaseRecord>: Sendable {
    public let record: Record
    public let changedFields: Set<Record.Field>
    public let isNew: Bool
}

/// Что транзакция изменила в базах (`NotesChanges.database`).
public struct DatabaseChanges: Sendable {
    public internal(set) var databases: [RecordChange<DatabaseSchema>] = []
    public internal(set) var properties: [RecordChange<DatabaseProperty>] = []
    public internal(set) var options: [RecordChange<SelectOption>] = []
    public internal(set) var views: [RecordChange<DatabaseView>] = []
    /// Ячейки, как они записаны (`value == nil` — пусто).
    public internal(set) var cells: [CellRecord] = []
    public internal(set) var relationLinks: [RecordChange<RelationLink>] = []
    public internal(set) var rowOrders: [RowOrder] = []

    public var isEmpty: Bool {
        databases.isEmpty && properties.isEmpty && options.isEmpty && views.isEmpty && cells.isEmpty && relationLinks.isEmpty
            && rowOrders.isEmpty
    }
}
