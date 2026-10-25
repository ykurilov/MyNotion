import Foundation
import GRDB
import NotesCore

/// Подписчик записи (research R3, R14): сравнимые колонки ячеек (`sortText`, `sortNumber`, `searchText`) и строки
/// `search_index` текстовых значений — в той же транзакции, что правка. Модель типа считает колонки; ядро о типах не знает.
/// Новые варианты, их перестановка и смена типа свойства переписывают колонки всех ячеек свойства; ячейка, пришедшая
/// раньше свойства, получает колонки, когда свойство придёт. Сравнимое название строки — строка `db_computed`
/// свойства «Название» (у названия нет ячейки).
public struct CellIndexer: NotesWriteHook {
    /// Типы, чей текст ищется поиском страниц (research R14).
    static let searchableKinds: Set<PropertyKind> = [.text, .url, .email, .phone, .select, .status, .multiSelect]

    public init() {}

    public func notesWillCommit(_ changes: NotesChanges, in transaction: NotesTransaction) throws {
        let db = transaction.database
        var run = Run(db: db, transaction: transaction)
        var reindex: Set<UUID> = []
        for change in changes.database.properties where change.isNew || change.changedFields.contains(.typeAndConfig) {
            reindex.insert(change.record.id)
        }
        // Один новый вариант (из ячейки по Enter, «+ Добавить вариант») встаёт на место `p`: у ячеек дальше по списку место
        // сдвигается на 1, остальное в ячейках не меняется — без переписывания всех строк (замер US2: 10 000 строк).
        var optionChanges: [UUID: [RecordChange<SelectOption>]] = [:]
        for change in changes.database.options { optionChanges[change.record.propertyId, default: []].append(change) }
        for (propertyId, list) in optionChanges {
            if !reindex.contains(propertyId), list.count == 1, let change = list.first, change.isNew, change.record.deletedAt == nil,
               let context = try run.context(propertyId), let position = context.options.firstIndex(where: { $0.id == change.record.id }) {
                try db.execute(sql: "UPDATE db_cell SET sortNumber = sortNumber + 1 WHERE propertyId = ? AND sortNumber >= ?",
                               arguments: [propertyId.databaseText, Double(position)])
                // Ячейки, пришедшие с другого Mac раньше варианта, получают колонки сейчас.
                let waiting = try Row.fetchAll(db, sql: "SELECT rowId, value FROM db_cell WHERE propertyId = ? AND instr(value, ?) > 0",
                                               arguments: [propertyId.databaseText, change.record.id.databaseText])
                for row in waiting {
                    guard let rowId = UUID(uuidString: row[0]) else { continue }
                    try run.index(rowId: rowId, propertyId: propertyId, value: (row[1] as String?).flatMap(JSONValue.init(jsonText:)))
                }
            } else {
                reindex.insert(propertyId)
            }
        }
        for propertyId in reindex { try run.reindex(propertyId) }
        for cell in changes.database.cells where !reindex.contains(cell.propertyId) {
            try run.index(rowId: cell.rowId, propertyId: cell.propertyId, value: cell.value)
        }
        for change in changes.pages where change.isNew || change.changedFields.contains(.title) || change.changedFields.contains(.placement) {
            try run.indexTitle(change.page)
        }
        for change in changes.database.databases where change.isNew { try run.indexTitles(ofDatabase: change.record.pageId) }
    }

    private struct Run {
        let db: Database
        let transaction: NotesTransaction
        var contexts: [UUID: PropertyContext?] = [:]
        var titleProperties: [UUID: UUID?] = [:]

        mutating func context(_ propertyId: UUID) throws -> PropertyContext? {
            if let known = contexts[propertyId] { return known }
            let context = try transaction.property(propertyId).map { property in
                PropertyContext(property: property, options: try transaction.options(ofProperty: property.id))
            }
            contexts[propertyId] = .some(context)
            return context
        }

        mutating func index(rowId: UUID, propertyId: UUID, value: JSONValue?) throws {
            guard let context = try context(propertyId), context.property.kind.storesCells else { return }
            let type = PropertyTypes.type(for: context.property.kind)
            let columns = value.map { type.comparables($0, in: context) } ?? CellComparables()
            try db.cachedStatement(sql: "UPDATE db_cell SET sortText = ?, sortNumber = ?, searchText = ? WHERE rowId = ? AND propertyId = ?")
                .execute(arguments: [columns.sortText, columns.sortNumber, columns.searchText, rowId.databaseText, propertyId.databaseText])
            guard CellIndexer.searchableKinds.contains(context.property.kind) else { return }
            let text = value.map { type.displayText($0, in: context) } ?? ""
            try writeSearch(rowId: rowId, propertyId: propertyId, text: text)
        }

        /// Строка поиска значения: номер — из `db_cell_search`, текст — как показывается («ё» как «е», как у страниц).
        func writeSearch(rowId: UUID, propertyId: UUID, text: String) throws {
            let offset = NotesTransaction.cellSearchRowidOffset
            let existing = try Int64.fetchOne(db.cachedStatement(sql: "SELECT searchRowid FROM db_cell_search WHERE rowId = ? AND propertyId = ?"),
                                              arguments: [rowId.databaseText, propertyId.databaseText])
            if let existing {
                try db.cachedStatement(sql: "DELETE FROM search_index WHERE rowid = ?").execute(arguments: [existing + offset])
            }
            guard !text.isEmpty else {
                if existing != nil {
                    try db.cachedStatement(sql: "DELETE FROM db_cell_search WHERE rowId = ? AND propertyId = ?")
                        .execute(arguments: [rowId.databaseText, propertyId.databaseText])
                }
                return
            }
            let number: Int64
            if let existing { number = existing } else {
                try db.cachedStatement(sql: "INSERT INTO db_cell_search (rowId, propertyId) VALUES (?, ?)")
                    .execute(arguments: [rowId.databaseText, propertyId.databaseText])
                number = db.lastInsertedRowID
            }
            let content = text.replacingOccurrences(of: "ё", with: "е").replacingOccurrences(of: "Ё", with: "Е")
            try db.cachedStatement(sql: "INSERT INTO search_index (rowid, pageId, blockId, content) VALUES (?, ?, NULL, ?)")
                .execute(arguments: [number + offset, rowId.databaseText, content])
        }

        /// Все ячейки свойства — заново (смена типа, варианты, свойство пришло после ячеек).
        mutating func reindex(_ propertyId: UUID) throws {
            contexts[propertyId] = nil
            if let kind = try context(propertyId)?.property.kind, !CellIndexer.searchableKinds.contains(kind) {
                // Тип сменили на неискомый: прежний текст ячеек уходит из поиска (⌘K).
                let offset = NotesTransaction.cellSearchRowidOffset
                try db.execute(sql: "DELETE FROM search_index WHERE rowid IN (SELECT searchRowid + \(offset) FROM db_cell_search WHERE propertyId = ?)",
                               arguments: [propertyId.databaseText])
                try db.execute(sql: "DELETE FROM db_cell_search WHERE propertyId = ?", arguments: [propertyId.databaseText])
            }
            if let property = try context(propertyId)?.property, property.kind == .title {
                titleProperties[property.databaseId] = nil
                try indexTitles(ofDatabase: property.databaseId)
                return
            }
            let rows = try Row.fetchAll(db, sql: "SELECT rowId, value FROM db_cell WHERE propertyId = ?", arguments: [propertyId.databaseText])
            for row in rows {
                guard let rowId = UUID(uuidString: row[0]) else { continue }
                try index(rowId: rowId, propertyId: propertyId, value: (row[1] as String?).flatMap(FastJSON.parse))
            }
        }

        mutating func titleProperty(ofDatabase databaseId: UUID) throws -> UUID? {
            if let known = titleProperties[databaseId] { return known }
            let found = try String.fetchOne(db, sql: "SELECT id FROM db_property WHERE databaseId = ? AND type = 'title' AND deletedAt IS NULL",
                                            arguments: [databaseId.databaseText]).flatMap(UUID.init(uuidString:))
            titleProperties[databaseId] = .some(found)
            return found
        }

        mutating func indexTitle(_ page: Page) throws {
            guard let parentId = page.parentId, let titleId = try titleProperty(ofDatabase: parentId) else { return }
            let columns = TextComparables.of(page.title)
            try db.cachedStatement(sql: """
                INSERT INTO db_computed (rowId, propertyId, value, sortText, searchText) VALUES (?, ?, NULL, ?, ?)
                ON CONFLICT(rowId, propertyId) DO UPDATE SET sortText = excluded.sortText, searchText = excluded.searchText
                """).execute(arguments: [page.id.databaseText, titleId.databaseText, columns.sortText, columns.searchText])
        }

        /// База появилась (или пришла с другого Mac после своих строк): названия всех её строк.
        mutating func indexTitles(ofDatabase databaseId: UUID) throws {
            for row in try Row.fetchAll(db, sql: "SELECT * FROM page WHERE parentId = ?", arguments: [databaseId.databaseText]) {
                try indexTitle(try Page(row: row))
            }
        }
    }
}
