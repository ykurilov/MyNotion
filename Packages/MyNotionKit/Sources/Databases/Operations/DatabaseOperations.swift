import Foundation
import NotesCore

/// Что создала операция «новая база».
public struct CreatedDatabase: Sendable, Hashable {
    public let databaseId: UUID
    public let viewId: UUID
    public let titlePropertyId: UUID
    /// Блок в странице-хозяине: ссылка на подстраницу (полностраничная) или блок `database` (встроенная).
    public let blockId: UUID?
}

/// Операции с базами (research R11) по образцу `PageTreeOperations` 001: одна правка — одна транзакция — один шаг
/// отмены в `undoManager` окна; обратная операция записывает прежние значения и сама ставит шаг повтора.
/// Здесь — основа (создать базу, добавить свойство, записать ячейку); истории пишут свои операции в файлах-расширениях
/// `DatabaseOperations+<Тема>.swift`.
@MainActor
public final class DatabaseOperations {
    public let store: NotesStore
    public weak var undoManager: UndoManager?
    /// После каждой успешной операции, в том числе отмены: чьи записи страниц или блоков она изменила (новая строка,
    /// название, корзина, блок базы в хозяине) — дереву и открытым страницам. Ячейки, свойства и виды сюда не входят:
    /// их ловят открытые таблицы по `didChange`, а страница базы не перечитывается из-за правки своей таблицы.
    public var onChange: ((Set<UUID>) -> Void)?
    /// Идущая фоновая перезапись свойства (большая смена типа и её отмена); следующая ждёт её.
    public internal(set) var pendingRewrite: Task<Void, any Error>?
    /// Отмена не удалась (например, строку уже стёрли навсегда).
    public var onUndoFailure: ((any Error) -> Void)?

    public init(store: NotesStore, undoManager: UndoManager? = nil) {
        self.store = store
        self.undoManager = undoManager
    }

    /// Одна правка: транзакция и шаг отмены (`inverse` — что сделать по ⌘Z).
    @discardableResult
    public func perform<T>(_ actionName: String, _ body: (NotesTransaction) throws -> (T, inverse: @MainActor (DatabaseOperations) throws -> Void)) throws -> T {
        var touched: Set<UUID> = []
        var pages: Set<UUID> = []
        let (result, inverse) = try store.write { transaction in
            let outcome = try body(transaction)
            touched = Self.touchedPages(transaction.changes)
            pages = Self.touchedPageRecords(transaction.changes)
            return outcome
        }
        registerUndo(actionName, inverse)
        Self.announce(touched)
        if !pages.isEmpty { onChange?(pages) }
        return result
    }

    /// Правка баз в любом окне (и её отмена) или правки с другого Mac: открытые таблицы и страницы строк перечитывают
    /// своё. `userInfo[touchedKey]` — затронутые базы и строки (`Set<UUID>`); без него — перечитать всё.
    public static let didChange = Notification.Name("DatabaseOperations.didChange")
    public static let touchedKey = "touched"

    /// Сообщить открытым видам баз: `nil` — изменилось неизвестно что (правки с другого Mac).
    public static func announce(_ touched: Set<UUID>?) {
        NotificationCenter.default.post(name: didChange, object: nil, userInfo: touched.map { [touchedKey: $0] })
    }

    public func registerUndo(_ actionName: String, _ inverse: @escaping @MainActor (DatabaseOperations) throws -> Void) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { operations in
            MainActor.assumeIsolated {
                do { try inverse(operations) } catch { operations.onUndoFailure?(error) }
            }
        }
        undoManager.setActionName(actionName)
    }

    /// Страницы, чьи записи или блоки изменились.
    nonisolated static func touchedPageRecords(_ changes: NotesChanges) -> Set<UUID> {
        var touched = Set(changes.pages.map(\.page.id)).union(changes.erasedPageIds)
        for change in changes.blocks {
            switch change {
            case .saved(let block, _, _): touched.insert(block.pageId)
            case .erased(_, let pageId): touched.insert(pageId)
            }
        }
        return touched
    }

    nonisolated static func touchedPages(_ changes: NotesChanges) -> Set<UUID> {
        var touched = Set(changes.pages.map(\.page.id)).union(changes.erasedPageIds)
        for change in changes.blocks {
            switch change {
            case .saved(let block, _, _): touched.insert(block.pageId)
            case .erased(_, let pageId): touched.insert(pageId)
            }
        }
        touched.formUnion(changes.database.databases.map(\.record.pageId))
        touched.formUnion(changes.database.properties.map(\.record.databaseId))
        touched.formUnion(changes.database.views.map(\.record.databaseId))
        touched.formUnion(changes.database.cells.map(\.rowId))
        touched.formUnion(changes.database.relationLinks.flatMap { [$0.record.rowId, $0.record.targetRowId] })
        return touched
    }

    // MARK: Создать базу

    /// «/База данных — на всю страницу» и «— встроенная» (spec, US1): пустая база с видом «Таблица» и колонкой
    /// «Название», строк нет. Полностраничная — подстраница со ссылкой у блока `placement`; встроенная — блок `database`
    /// там же. Без хозяина (`parentId == nil`) — база в корне дерева.
    @discardableResult
    public func createDatabase(in parentId: UUID?, isInline: Bool, title: String = "", linkAt placement: SubpageLinkPlacement? = nil) throws -> CreatedDatabase {
        let (created, replaced) = try perform(isInline ? "Новая встроенная база" : "Новая база") { transaction -> ((CreatedDatabase, Block?), inverse: @MainActor (DatabaseOperations) throws -> Void) in
            var page = try transaction.createPage(title: title, parentId: parentId)
            // Страница-база — во всю ширину окна, как у Notion 7.39 (`notion-db-fullpage-open-from-inline.png`).
            page.isFullWidth = true
            page = try transaction.updatePage(page)
            // У страницы-базы своих блоков нет: её содержимое — строки.
            for block in try transaction.blocks(ofPage: page.id) { try transaction.deleteBlock(block.id) }
            try transaction.saveDatabase(DatabaseSchema(pageId: page.id, isInline: isInline))
            let titleProperty = try transaction.saveProperty(DatabaseProperty(databaseId: page.id, name: "Название", kind: .title,
                                                                              sortKey: .between(nil, nil)))
            let view = try transaction.saveView(DatabaseView(databaseId: page.id, sortKey: .between(nil, nil),
                                                             columns: [["propertyId": .string(titleProperty.id.uuidString.lowercased()),
                                                                        "isVisible": true, "width": 280]],
                                                             layoutOptions: ["openRowsIn": "sidePeek", "loadLimit": 50, "wrapAllContent": false]))
            var blockId: UUID?
            var replaced: Block?
            if let parentId {
                let placed = try Self.placeBlock(kind: isInline ? .database : .pageLink, linking: page.id, in: parentId, at: placement, transaction)
                blockId = placed.block.id
                replaced = placed.replaced
            }
            let created = CreatedDatabase(databaseId: page.id, viewId: view.id, titlePropertyId: titleProperty.id, blockId: blockId)
            return ((created, replaced), { try $0.withdraw(created, replaced: replaced) })
        }
        _ = replaced
        return created
    }

    /// Отмена создания: база — в корзину (набранное в ней цело), блок в хозяине убирается, заменённый абзац возвращается.
    private func withdraw(_ created: CreatedDatabase, replaced: Block?) throws {
        try perform("Новая база") { transaction -> (Void, inverse: @MainActor (DatabaseOperations) throws -> Void) in
            if var page = try transaction.page(created.databaseId), page.trashedAt == nil {
                page.trashedAt = Date()
                try transaction.updatePage(page)
            }
            if let blockId = created.blockId, try transaction.block(blockId) != nil { try transaction.deleteBlock(blockId) }
            if let replaced { try transaction.insertBlock(replaced) }
            return ((), { try $0.reinstate(created, replaced: replaced) })
        }
    }

    /// Повтор создания: база из корзины, блок — на прежнее место.
    private func reinstate(_ created: CreatedDatabase, replaced: Block?) throws {
        try perform("Новая база") { transaction -> (Void, inverse: @MainActor (DatabaseOperations) throws -> Void) in
            guard var page = try transaction.page(created.databaseId) else { throw NotesStoreError.pageNotFound(created.databaseId) }
            page.trashedAt = nil
            try transaction.updatePage(page)
            if let blockId = created.blockId, let parentId = page.parentId, let kind: BlockKind = (try transaction.database(page.id)).map({ $0.isInline ? .database : .pageLink }) {
                let lastKey = try transaction.blocks(ofPage: parentId).last?.sortKey
                let sortKey = replaced?.sortKey ?? FractionalSortKey.between(lastKey, nil)
                if let replaced, try transaction.block(replaced.id) != nil { try transaction.deleteBlock(replaced.id) }
                try transaction.insertBlock(Block(id: blockId, pageId: parentId, kind: kind, indent: replaced?.indent ?? 0, linkedPageId: page.id,
                                                  sortKey: sortKey, containerId: replaced?.containerId))
            }
            return ((), { try $0.withdraw(created, replaced: replaced) })
        }
    }

    /// Блок-ссылка на базу у блока `placement`: вместо него (пустой абзац) или сразу после; без места — в конце.
    static func placeBlock(kind: BlockKind, linking pageId: UUID, in parentId: UUID, at placement: SubpageLinkPlacement?,
                           _ transaction: NotesTransaction) throws -> (block: Block, replaced: Block?) {
        let blocks = try transaction.blocks(ofPage: parentId)
        switch placement {
        case .replacing(let anchorId)?:
            guard let anchor = blocks.first(where: { $0.id == anchorId }) else { throw NotesStoreError.blockNotFound(anchorId) }
            try transaction.deleteBlock(anchor.id)
            let block = try transaction.insertBlock(Block(pageId: parentId, kind: kind, indent: anchor.indent, linkedPageId: pageId,
                                                          sortKey: anchor.sortKey, containerId: anchor.containerId))
            return (block, anchor)
        case .after(let anchorId)?:
            guard let anchor = blocks.first(where: { $0.id == anchorId }) else { throw NotesStoreError.blockNotFound(anchorId) }
            let next = blocks.filter { $0.containerId == anchor.containerId && $0.sortKey > anchor.sortKey }.map(\.sortKey).min()
            let block = try transaction.insertBlock(Block(pageId: parentId, kind: kind, indent: anchor.indent, linkedPageId: pageId,
                                                          sortKey: .between(anchor.sortKey, next), containerId: anchor.containerId))
            return (block, nil)
        case nil:
            let last = blocks.filter { $0.containerId == nil }.map(\.sortKey).max()
            return (try transaction.insertBlock(Block(pageId: parentId, kind: kind, linkedPageId: pageId, sortKey: .between(last, nil))), nil)
        }
    }

    // MARK: Свойство и ячейка

    /// Новое свойство в конце базы (колонка — в конце видов: свойства не из списка вида — видимые, в конце).
    /// ⌘Z — в «Удалённые свойства» (значения хранятся), ⇧⌘Z — обратно.
    @discardableResult
    public func addProperty(to databaseId: UUID, name: String, kind: PropertyKind, config: JSONValue = .emptyObject) throws -> DatabaseProperty {
        try perform("Новое свойство") { transaction in
            if kind == .uniqueId { try UniqueIds.ensureNone(inDatabase: databaseId, in: transaction) }
            let last = try transaction.properties(ofDatabase: databaseId, includingDeleted: true).map(\.sortKey).max()
            let property = try transaction.saveProperty(DatabaseProperty(databaseId: databaseId, name: name, kind: kind, config: config,
                                                                         sortKey: .between(last, nil)))
            // Новое ID нумерует прежние строки по созданию (Notion 7.39).
            if kind == .uniqueId { try UniqueIds.numberRows(of: property.id, inDatabase: databaseId, in: transaction) }
            // Новый статус — с группами и вариантами Notion (US2).
            if kind == .status { try Self.insertStatusDefaults(in: property.id, transaction) }
            return (property, { try $0.setDeleted(property.id, true) })
        }
    }

    /// Убрать свойство в «Удалённые свойства» или вернуть (значения не трогаются).
    public func setDeleted(_ propertyId: UUID, _ isDeleted: Bool) throws {
        try perform(isDeleted ? "Удаление свойства" : "Возврат свойства") { transaction in
            guard var property = try transaction.property(propertyId) else { throw NotesStoreError.invalidRecord("свойства нет") }
            // «Название» не удаляется (FR-305); удалённое навсегда не возвращается (US1, `eraseProperty`).
            guard property.kind != .title, property.config[Self.erasedKey] == nil else {
                throw NotesStoreError.invalidRecord("это свойство не удаляется и не возвращается")
            }
            if !isDeleted, property.kind == .uniqueId { try UniqueIds.ensureNone(inDatabase: property.databaseId, except: propertyId, in: transaction) }
            property.deletedAt = isDeleted ? Date() : nil
            try transaction.saveProperty(property)
            return ((), { try $0.setDeleted(propertyId, !isDeleted) })
        }
    }

    /// Записать значение ячейки (`nil` — пусто); ⌘Z возвращает прежнее.
    public func setCell(rowId: UUID, propertyId: UUID, value: JSONValue?) throws {
        try perform("Правка значения") { transaction in
            let previous = try transaction.cell(rowId: rowId, propertyId: propertyId)?.value
            try transaction.setCell(rowId: rowId, propertyId: propertyId, value: value)
            return ((), { try $0.setCell(rowId: rowId, propertyId: propertyId, value: previous) })
        }
    }
}
