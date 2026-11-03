import Foundation
import GRDB
import NotesCore

/// Итог формулы или сводки для строки (data-model.md, `db_computed`).
public struct ComputedValue: Sendable, Hashable {
    public var rowId: UUID
    public var propertyId: UUID
    /// `nil` — пусто.
    public var value: JSONValue?
    /// Формула с `now()` / `today()`.
    public var isLive: Bool

    public init(rowId: UUID, propertyId: UUID, value: JSONValue?, isLive: Bool = false) {
        self.rowId = rowId
        self.propertyId = propertyId
        self.value = value
        self.isLive = isLive
    }
}

/// Запись итогов в `db_computed` со сравнимыми колонками — тем же кодом типа, что ячейки (research R6, R21).
public enum ComputedWriter {
    static let upsert = """
        INSERT INTO db_computed (rowId, propertyId, value, sortText, sortNumber, searchText, isLive) VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(rowId, propertyId) DO UPDATE SET value = excluded.value, sortText = excluded.sortText,
            sortNumber = excluded.sortNumber, searchText = excluded.searchText, isLive = excluded.isLive
        WHERE db_computed.value IS NOT excluded.value OR db_computed.sortText IS NOT excluded.sortText
            OR db_computed.sortNumber IS NOT excluded.sortNumber OR db_computed.searchText IS NOT excluded.searchText
            OR db_computed.isLive IS NOT excluded.isLive
        """

    /// В транзакции правки: итоги её строк. Совпадающий кэш не переписывает вторичные индексы.
    /// NULL-итог без записи вставляется: наличие строки отмечает завершённое вычисление.
    /// Часы/события правки принадлежат NotesTransaction и ComputationHook, а не локальному кэшу.
    public static func write(_ values: [ComputedValue], in transaction: NotesTransaction) throws {
        try write(values, in: transaction.database)
    }

    static func write(_ values: [ComputedValue], in db: Database) throws {
        let statement = try db.cachedStatement(sql: upsert)
        for item in values { try statement.execute(arguments: arguments(item)) }
    }

    /// Пачка фонового пересчёта (R21): строка, у которой метка уже не та, что при чтении, не трогается — её поправили
    /// после чтения, или правка другой строки пересчитала её итоги в своей записи. Возвращает пропущенные строки.
    static func write(_ values: [ComputedValue], readStamps: [UUID: String], in db: Database) throws -> Set<UUID> {
        var skipped: Set<UUID> = []
        let rows = Array(Set(values.map(\.rowId)))
        let current = try rowStamps(rows, in: db)
        for row in rows where current[row] != readStamps[row] { skipped.insert(row) }
        let statement = try db.cachedStatement(sql: upsert)
        for item in values where !skipped.contains(item.rowId) { try statement.execute(arguments: arguments(item)) }
        return skipped
    }

    /// Метка строки для сверки фоновой пачки: `updatedAt` и все итоги строки. Правка связанной строки итоги этой
    /// пересчитывает, а `updatedAt` не трогает.
    static func rowStamps(_ rows: [UUID], in db: Database) throws -> [UUID: String] {
        var stamps: [UUID: String] = [:]
        try SQLChunks.forEach(rows) { marks, arguments in
            for row in try Row.fetchAll(db, sql: """
                SELECT id, CAST(updatedAt AS TEXT) || char(10) || ifnull((SELECT group_concat(item, char(10)) FROM (
                    SELECT propertyId || '=' || ifnull(value, '') AS item FROM db_computed WHERE rowId = page.id ORDER BY propertyId)), '')
                FROM page WHERE id IN (\(marks))
                """, arguments: arguments) {
                if let id = UUID(uuidString: row[0]) { stamps[id] = row[1] }
            }
        }
        return stamps
    }

    private static func arguments(_ item: ComputedValue) -> StatementArguments {
        let property = DatabaseProperty(id: item.propertyId, databaseId: item.propertyId, name: "итог", kind: .formula, sortKey: .between(nil, nil))
        let columns = item.value.map { PropertyTypes.type(for: .formula).comparables($0, in: PropertyContext(property: property)) } ?? CellComparables()
        return [item.rowId.databaseText, item.propertyId.databaseText, item.value.map(\.jsonText), columns.sortText, columns.sortNumber,
                columns.searchText, item.isLive]
    }
}
