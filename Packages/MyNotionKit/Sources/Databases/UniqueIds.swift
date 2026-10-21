import Foundation
import GRDB
import NotesCore

/// Номера свойства ID (research R9): номер новой строки — наибольший известный этому Mac номер в базе + 1, по индексу
/// `sortNumber`. Строки в корзине свои ячейки хранят, поэтому их номера не выдаются снова. Одно свойство ID на базу.
/// Починку совпавших номеров после синхронизации добавит этап «Сквозное» (T104).
enum UniqueIds {
    /// Неудалённое свойство ID базы.
    static func property(ofDatabase databaseId: UUID, in transaction: NotesTransaction) throws -> DatabaseProperty? {
        try transaction.properties(ofDatabase: databaseId).first { $0.kind == .uniqueId }
    }

    /// Следующий свободный номер свойства. Сравнимые колонки пишет `CellIndexer` перед концом транзакции, поэтому
    /// номера, выданные в этой же транзакции, ещё без `sortNumber` — их видно по самому значению.
    static func nextNumber(of propertyId: UUID, in transaction: NotesTransaction) throws -> Int {
        let id = propertyId.databaseText
        let indexed = try Double.fetchOne(transaction.database, sql: "SELECT MAX(sortNumber) FROM db_cell WHERE propertyId = ?",
                                          arguments: [id]) ?? 0
        let fresh = try Double.fetchOne(transaction.database, sql: """
            SELECT MAX(CAST(value AS REAL)) FROM db_cell WHERE propertyId = ? AND sortNumber IS NULL AND value IS NOT NULL
            """, arguments: [id]) ?? 0
        return Int(max(indexed, fresh)) + 1
    }

    /// Номер новой строке, если в базе есть ID.
    static func assign(toRow rowId: UUID, ofDatabase databaseId: UUID, in transaction: NotesTransaction) throws {
        guard let property = try property(ofDatabase: databaseId, in: transaction) else { return }
        try transaction.setCell(rowId: rowId, propertyId: property.id, value: .number(Double(try nextNumber(of: property.id, in: transaction))))
    }

    /// Новое свойство ID (или смена типа на ID): строки без номера получают номера по созданию, после уже выданных.
    static func numberRows(of propertyId: UUID, inDatabase databaseId: UUID, in transaction: NotesTransaction) throws {
        var next = try nextNumber(of: propertyId, in: transaction)
        let unnumbered = try String.fetchAll(transaction.database, sql: """
            SELECT p.id FROM page p LEFT JOIN db_cell c ON c.rowId = p.id AND c.propertyId = ?
            WHERE p.parentId = ? AND p.isTemplate = 0 AND (c.value IS NULL)
            ORDER BY p.createdAt, p.id
            """, arguments: [propertyId.databaseText, databaseId.databaseText]).compactMap(UUID.init(uuidString:))
        for rowId in unnumbered {
            try transaction.setCell(rowId: rowId, propertyId: propertyId, value: .number(Double(next)))
            next += 1
        }
    }

    /// Второе свойство ID в базе не заводится (spec, Notion 7.39: в списке типов ID серый).
    static func ensureNone(inDatabase databaseId: UUID, except propertyId: UUID? = nil, in transaction: NotesTransaction) throws {
        if let existing = try property(ofDatabase: databaseId, in: transaction), existing.id != propertyId {
            throw NotesStoreError.invalidRecord("в базе уже есть свойство ID")
        }
    }
}
