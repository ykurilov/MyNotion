import Foundation
import GRDB
import NotesCore

/// Куда встаёт новая строка в виде (contracts/database-ui.md, «Строки»).
public enum NewRowPlacement: Sendable, Hashable {
    /// «+ Новая строка» внизу таблицы.
    case bottom
    /// «Создать» в строке вида: вверх вида.
    case top
    /// «+» при наведении: сразу под строкой.
    case after(UUID)
}

/// Строки (US1, research R11): новая, копия, в корзину, перетаскивание. Строка — страница-ребёнок базы; место в виде —
/// `db_row_order` этого вида, иначе `Page.sortKey` (у каждого вида свой ручной порядок, notion-survey.md, п. 1).
extension DatabaseOperations {
    /// Новая строка с номером ID (если он есть в базе). ⌘Z — в корзину, ⇧⌘Z — обратно.
    @discardableResult
    public func addRow(to databaseId: UUID, in viewId: UUID?, at placement: NewRowPlacement = .bottom, title: String = "") throws -> UUID {
        try perform("Новая строка") { transaction in
            let rowId = try Self.writeRow(in: databaseId, viewId: viewId, placement: placement, title: title, transaction)
            return (rowId, { try $0.setRowsTrashed([rowId], true) })
        }
    }

    /// «Дублировать» (меню строки ⌘D, полоса «N выбрано»): копия со своими блоками и значениями — сразу под строкой,
    /// название «Имя (1)», свой номер ID. Возвращает копии в порядке строк.
    @discardableResult
    public func duplicateRows(_ rowIds: [UUID], in viewId: UUID?) throws -> [UUID] {
        try perform("Дублирование строки") { transaction in
            var copies: [UUID] = []
            for rowId in rowIds {
                guard let original = try transaction.page(rowId), let databaseId = original.parentId else { throw NotesStoreError.pageNotFound(rowId) }
                let nextPageKey = try String.fetchOne(transaction.database, sql: """
                    SELECT MIN(sortKey) FROM page WHERE parentId = ? AND sortKey > ? AND trashedAt IS NULL
                    """, arguments: [databaseId.databaseText, original.sortKey.rawValue]).flatMap(FractionalSortKey.init(rawValue:))
                let result = try PageBranchCopier.copy(rowId, in: transaction, title: try Self.copyTitle(of: original, in: databaseId, transaction),
                                                       parentId: databaseId, sortKey: Self.key(between: original.sortKey, nextPageKey))
                let uniqueId = try UniqueIds.property(ofDatabase: databaseId, in: transaction)?.id
                for cell in try transaction.cells(ofRow: rowId) where cell.propertyId != uniqueId && cell.value != nil {
                    try transaction.setCell(rowId: result.rootId, propertyId: cell.propertyId, value: cell.value)
                }
                try UniqueIds.assign(toRow: result.rootId, ofDatabase: databaseId, in: transaction)
                if let viewId, try Self.hasManualOrder(viewId, transaction) {
                    let key = try Self.viewKey(of: rowId, in: viewId, transaction)
                    let next = try Self.viewKey(after: key, in: viewId, databaseId: databaseId, excluding: result.rootId, transaction)
                    try transaction.setRowOrder(viewId: viewId, rowId: result.rootId, sortKey: Self.key(between: key, next))
                }
                copies.append(result.rootId)
            }
            return (copies, { try $0.setRowsTrashed(copies, true) })
        }
    }

    /// Строки в корзину (меню строки, ⌫ по выбранным строкам); ячейки остаются при строках.
    public func trashRows(_ rowIds: [UUID]) throws {
        try setRowsTrashed(rowIds, true)
    }

    /// В корзину или обратно; шаг отмены — противоположное.
    func setRowsTrashed(_ rowIds: [UUID], _ isTrashed: Bool) throws {
        try perform(isTrashed ? "Удаление строки" : "Возврат строки") { transaction in
            let now = Date()
            for rowId in rowIds {
                guard var page = try transaction.page(rowId) else { throw NotesStoreError.pageNotFound(rowId) }
                guard (page.trashedAt != nil) != isTrashed else { continue }
                page.trashedAt = isTrashed ? now : nil
                try transaction.updatePage(page)
            }
            return ((), { try $0.setRowsTrashed(rowIds, !isTrashed) })
        }
    }

    /// Перетащить строки в виде между `previousId` и `nextId` (`nil` — край): меняется только ручной порядок этого вида.
    public func moveRows(_ rowIds: [UUID], in viewId: UUID, between previousId: UUID?, and nextId: UUID?) throws {
        try perform("Перемещение строки") { transaction in
            let previousKeys = try rowIds.map { try Self.viewKey(of: $0, in: viewId, transaction) }
            var lower = try previousId.map { try Self.viewKey(of: $0, in: viewId, transaction) }
            let upper = try nextId.map { try Self.viewKey(of: $0, in: viewId, transaction) }
            for rowId in rowIds {
                let key = Self.key(between: lower, upper)
                try transaction.setRowOrder(viewId: viewId, rowId: rowId, sortKey: key)
                lower = key
            }
            return ((), { try $0.setRowOrders(Array(zip(rowIds, previousKeys)), in: viewId) })
        }
    }

    func setRowOrders(_ orders: [(UUID, FractionalSortKey)], in viewId: UUID) throws {
        try perform("Перемещение строки") { transaction in
            let previous = try orders.map { ($0.0, try Self.viewKey(of: $0.0, in: viewId, transaction)) }
            for (rowId, key) in orders { try transaction.setRowOrder(viewId: viewId, rowId: rowId, sortKey: key) }
            return ((), { try $0.setRowOrders(previous, in: viewId) })
        }
    }

    // MARK: Внутреннее

    /// Записать новую строку в открытой транзакции (строка таблицы, вставка из буфера).
    nonisolated static func writeRow(in databaseId: UUID, viewId: UUID?, placement: NewRowPlacement, title: String, _ transaction: NotesTransaction) throws -> UUID {
        guard try transaction.database(databaseId) != nil else { throw NotesStoreError.invalidRecord("это не база") }
        let page = try transaction.createPage(title: title, parentId: databaseId)
        try UniqueIds.assign(toRow: page.id, ofDatabase: databaseId, in: transaction)
        guard let viewId else { return page.id }
        switch placement {
        case .bottom:
            // Строка в конце страниц; если ручной порядок вида дальше — ещё и место в виде.
            if let last = try viewEdgeKey(in: viewId, databaseId: databaseId, excluding: page.id, largest: true, transaction), !(last < page.sortKey) {
                try transaction.setRowOrder(viewId: viewId, rowId: page.id, sortKey: .between(last, nil))
            }
        case .top:
            let first = try viewEdgeKey(in: viewId, databaseId: databaseId, excluding: page.id, largest: false, transaction)
            try transaction.setRowOrder(viewId: viewId, rowId: page.id, sortKey: .between(nil, first))
        case .after(let anchorId):
            let key = try viewKey(of: anchorId, in: viewId, transaction)
            let next = try viewKey(after: key, in: viewId, databaseId: databaseId, excluding: page.id, transaction)
            try transaction.setRowOrder(viewId: viewId, rowId: page.id, sortKey: Self.key(between: key, next))
        }
        return page.id
    }

    /// Место строки в виде: ручное этого вида или место страницы.
    nonisolated static func viewKey(of rowId: UUID, in viewId: UUID, _ transaction: NotesTransaction) throws -> FractionalSortKey {
        if let order = try transaction.rowOrder(viewId: viewId, rowId: rowId) { return order.sortKey }
        guard let page = try transaction.page(rowId) else { throw NotesStoreError.pageNotFound(rowId) }
        return page.sortKey
    }

    nonisolated private static let viewKeySQL = "COALESCE(o.sortKey, p.sortKey)"
    nonisolated private static let viewRowsSQL = """
        FROM page p LEFT JOIN db_row_order o ON o.viewId = ? AND o.rowId = p.id
        WHERE p.parentId = ? AND p.trashedAt IS NULL AND p.isTemplate = 0 AND p.id != ?
        """

    nonisolated static func viewEdgeKey(in viewId: UUID, databaseId: UUID, excluding rowId: UUID, largest: Bool, _ transaction: NotesTransaction) throws -> FractionalSortKey? {
        try String.fetchOne(transaction.database, sql: "SELECT \(largest ? "MAX" : "MIN")(\(viewKeySQL)) \(viewRowsSQL)",
                            arguments: [viewId.databaseText, databaseId.databaseText, rowId.databaseText]).flatMap(FractionalSortKey.init(rawValue:))
    }

    nonisolated static func viewKey(after key: FractionalSortKey, in viewId: UUID, databaseId: UUID, excluding rowId: UUID,
                        _ transaction: NotesTransaction) throws -> FractionalSortKey? {
        try String.fetchOne(transaction.database, sql: "SELECT MIN(\(viewKeySQL)) \(viewRowsSQL) AND \(viewKeySQL) > ?",
                            arguments: [viewId.databaseText, databaseId.databaseText, rowId.databaseText, key.rawValue])
            .flatMap(FractionalSortKey.init(rawValue:))
    }

    nonisolated static func hasManualOrder(_ viewId: UUID, _ transaction: NotesTransaction) throws -> Bool {
        try Bool.fetchOne(transaction.database, sql: "SELECT EXISTS (SELECT 1 FROM db_row_order WHERE viewId = ?)",
                          arguments: [viewId.databaseText]) ?? false
    }

    /// «Имя (1)»; занято в базе — «(2)» и дальше (как «Дублировать» страницы 003).
    nonisolated static func copyTitle(of row: Page, in databaseId: UUID, _ transaction: NotesTransaction) throws -> String {
        let base = row.displayTitle
        let taken = Set(try String.fetchAll(transaction.database, sql: """
            SELECT title FROM page WHERE parentId = ? AND trashedAt IS NULL AND substr(title, 1, ?) = ?
            """, arguments: [databaseId.databaseText, base.count + 2, base + " ("]))
        var number = 1
        while taken.contains("\(base) (\(number))") { number += 1 }
        return "\(base) (\(number))"
    }
}
