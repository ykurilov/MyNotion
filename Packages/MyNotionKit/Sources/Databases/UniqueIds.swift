import Foundation
import GRDB
import NotesCore

/// Номера свойства ID (research R9): номер новой строки — наибольший известный этому Mac номер в базе + 1, по индексу
/// `sortNumber`. Строки в корзине свои ячейки хранят, поэтому их номера не выдаются снова. Одно свойство ID на базу.
/// Совпавшие после синхронизации номера разводит `repairDuplicates`.
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

    /// Строки, чей номер уже есть у строки с более ранним `(createdAt, id)` той же базы, — по порядку создания.
    /// Номера сравниваются по `sortNumber`: его пишет `CellIndexer` в транзакции приёма, поэтому поиск идёт по индексу.
    static func duplicateRows(in db: Database) throws -> [(rowId: UUID, propertyId: UUID)] {
        try Row.fetchAll(db, sql: """
            SELECT c.rowId, c.propertyId FROM db_property pr
            JOIN db_cell c ON c.propertyId = pr.id AND c.sortNumber IS NOT NULL
            JOIN page p ON p.id = c.rowId AND p.parentId = pr.databaseId AND p.isTemplate = 0
            WHERE pr.type = 'uniqueId' AND pr.deletedAt IS NULL AND EXISTS (
                SELECT 1 FROM db_cell d JOIN page q ON q.id = d.rowId AND q.parentId = pr.databaseId AND q.isTemplate = 0
                WHERE d.propertyId = c.propertyId AND d.sortNumber = c.sortNumber AND d.rowId != c.rowId
                  AND (q.createdAt < p.createdAt OR (q.createdAt = p.createdAt AND q.id < p.id)))
            ORDER BY p.createdAt, p.id
            """).compactMap { row in
            guard let rowId = UUID(uuidString: row[0]), let propertyId = UUID(uuidString: row[1]) else { return nil }
            return (rowId, propertyId)
        }
    }

    /// Совпавшие номера после синхронизации (research R9): строка с более поздним `(createdAt, id)` получает следующий
    /// свободный номер обычной правкой ячейки — правка уходит на другие Mac. Починка на двух Mac сразу даёт той же строке
    /// тот же номер или сходится по «позднее побеждает»; остаток ловит следующая проверка. Возвращает перенумерованные строки.
    static func repairDuplicates(in transaction: NotesTransaction) throws -> Set<UUID> {
        var repaired: Set<UUID> = []
        // Переписанная ячейка до конца транзакции хранит прежний `sortNumber`: следующие номера считаются здесь.
        var next: [UUID: Int] = [:]
        for (rowId, propertyId) in try duplicateRows(in: transaction.database) {
            let number = try next[propertyId] ?? nextNumber(of: propertyId, in: transaction)
            try transaction.setCell(rowId: rowId, propertyId: propertyId, value: .number(Double(number)))
            next[propertyId] = number + 1
            repaired.insert(rowId)
        }
        return repaired
    }

    /// Второе свойство ID в базе не заводится (spec, Notion 7.39: в списке типов ID серый).
    static func ensureNone(inDatabase databaseId: UUID, except propertyId: UUID? = nil, in transaction: NotesTransaction) throws {
        if let existing = try property(ofDatabase: databaseId, in: transaction), existing.id != propertyId {
            throw NotesStoreError.invalidRecord("в базе уже есть свойство ID")
        }
    }
}

extension DatabaseOperations {
    /// После правок с другого Mac: развести совпавшие номера ID (`UniqueIds.repairDuplicates`). Без совпадений — только чтение.
    @discardableResult
    public static func repairDuplicateIds(in store: NotesStore) throws -> Set<UUID> {
        guard try !store.database.dbWriter.read({ try UniqueIds.duplicateRows(in: $0) }).isEmpty else { return [] }
        let repaired = try store.write { try UniqueIds.repairDuplicates(in: $0) }
        if !repaired.isEmpty { announce(repaired) }
        return repaired
    }
}
