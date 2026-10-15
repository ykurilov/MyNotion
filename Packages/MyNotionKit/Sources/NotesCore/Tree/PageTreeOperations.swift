import Foundation

/// Операции с деревом страниц (FR-001…FR-005, FR-012). Каждая — одна транзакция хранилища,
/// поэтому подписчики (поиск, синхронизация) видят страницу и ссылку на неё в родителе вместе.
/// Отмена ставится в `undoManager` окна; удаление навсегда не отменяется.
@MainActor
public final class PageTreeOperations {
    public let store: NotesStore
    /// Отмена окна: ⌘Z / ⇧⌘Z общие с редактором.
    public weak var undoManager: UndoManager?
    /// После каждой успешной операции, в том числе отмены: какие страницы она затронула.
    public var onChange: ((Set<UUID>) -> Void)?
    /// Отмена не удалась (например, страницу уже стёрли навсегда).
    public var onUndoFailure: ((any Error) -> Void)?

    public init(store: NotesStore, undoManager: UndoManager? = nil) {
        self.store = store
        self.undoManager = undoManager
    }

    // MARK: Создать, переименовать

    /// Подстраница — пара: страница с `parentId` последней среди соседей и блок-ссылка в конце родителя.
    @discardableResult
    public func createSubpage(in parentId: UUID, title: String = "") throws -> Page {
        let page = try perform { transaction in
            guard try transaction.page(parentId) != nil else { throw NotesStoreError.pageNotFound(parentId) }
            let page = try transaction.createPage(title: title, parentId: parentId)
            try Self.appendLink(to: page.id, in: parentId, transaction)
            return page
        }
        // Отмена создания уводит страницу в корзину: набранное в ней за это время не пропадает.
        registerUndo("Новая подстраница") { try $0.moveToTrash(page.id) }
        return page
    }

    public func rename(_ pageId: UUID, to title: String) throws {
        let oldTitle = try perform { transaction in
            guard var page = try transaction.page(pageId) else { throw NotesStoreError.pageNotFound(pageId) }
            let oldTitle = page.title
            page.title = title
            try transaction.updatePage(page)
            return oldTitle
        }
        guard oldTitle != title else { return }
        registerUndo("Переименование") { try $0.rename(pageId, to: oldTitle) }
    }

    // MARK: Перенос

    /// Можно ли положить страницу внутрь `parentId` (`nil` — в корень): не в себя и не в свою ветку.
    public func canMove(_ pageId: UUID, toParent parentId: UUID?) throws -> Bool {
        guard let parentId else { return true }
        let tree = try store.pageTree()
        return tree.page(parentId) != nil && !tree.isPage(parentId, insideBranchOf: pageId)
    }

    /// Перенести страницу с веткой внутрь `parentId` (`nil` — корень) на место `index` среди новых соседей.
    public func move(_ pageId: UUID, toParent parentId: UUID?, at index: Int) throws {
        try place(pageId, actionName: "Перенос страницы") { transaction in
            let tree = PageTreeSnapshot(allPages: try transaction.allPages())
            if let parentId {
                guard tree.page(parentId) != nil else { throw NotesStoreError.pageNotFound(parentId) }
                guard !tree.isPage(parentId, insideBranchOf: pageId) else {
                    throw NotesStoreError.invalidPage("страница не может лежать внутри себя или своей подстраницы")
                }
            }
            let siblings = tree.children(of: parentId).filter { $0.id != pageId }
            let position = min(max(index, 0), siblings.count)
            let previous = position > 0 ? siblings[position - 1].sortKey : nil
            var next = position < siblings.count ? siblings[position].sortKey : nil
            if let previous, let nextKey = next, !(previous < nextKey) { next = nil }
            return (parentId, FractionalSortKey.between(previous, next))
        }
    }

    // MARK: Корзина

    /// В корзину — вместе с подстраницами; ссылка из родителя убирается.
    public func moveToTrash(_ pageId: UUID) throws {
        let didTrash = try perform { transaction in
            guard var page = try transaction.page(pageId) else { throw NotesStoreError.pageNotFound(pageId) }
            guard page.trashedAt == nil else { return false }
            page.trashedAt = Date()
            try transaction.updatePage(page)
            if let parentId = page.parentId {
                try Self.removeLinks(to: pageId, in: parentId, transaction)
            }
            return true
        }
        if didTrash { registerUndo("Удаление в корзину") { try $0.restore(pageId) } }
    }

    /// Вернуть из корзины на прежнее место; если родитель исчез — в корень.
    public func restore(_ pageId: UUID) throws {
        try perform { transaction in
            guard var page = try transaction.page(pageId) else { throw NotesStoreError.pageNotFound(pageId) }
            guard page.trashedAt != nil else { throw NotesStoreError.invalidPage("страницы нет в корзине") }
            page.trashedAt = nil
            if let parentId = page.parentId, try transaction.page(parentId) == nil {
                let lastRootKey = try transaction.allPages().filter { $0.parentId == nil }.map(\.sortKey).max()
                page.parentId = nil
                page.sortKey = .between(lastRootKey, nil)
            }
            try transaction.updatePage(page)
            if let parentId = page.parentId {
                try Self.appendLink(to: pageId, in: parentId, transaction)
            }
        }
        registerUndo("Возврат из корзины") { try $0.moveToTrash(pageId) }
    }

    /// Стереть страницу из корзины вместе с веткой; остаются надгробия. Не отменяется.
    /// Подстраница, которую удалили в корзину отдельно раньше, остаётся в корзине своей записью.
    public func deleteForever(_ pageId: UUID) throws {
        try perform { transaction in
            let all = try transaction.allPages()
            let byId = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
            guard let page = byId[pageId] else { throw NotesStoreError.pageNotFound(pageId) }
            guard PageTreeSnapshot.isInTrash(page, pagesById: byId) else {
                throw NotesStoreError.invalidPage("навсегда удаляется только страница из корзины")
            }
            let children = Dictionary(grouping: all, by: \.parentId)
            var branch: [Page] = []
            func collect(_ page: Page) {
                branch.append(page)
                for child in children[page.id] ?? [] where child.trashedAt == nil {
                    collect(child)
                }
            }
            collect(page)
            try Self.erase(branch, transaction)
        }
    }

    /// Стереть всё, что в корзине, одной транзакцией.
    public func emptyTrash() throws {
        try perform { transaction in
            let all = try transaction.allPages()
            let byId = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
            try Self.erase(all.filter { PageTreeSnapshot.isInTrash($0, pagesById: byId) }, transaction)
        }
    }

    // MARK: Внутреннее

    /// Новое место страницы; отмена ставит её точно на прежнее.
    private func place(
        _ pageId: UUID,
        actionName: String,
        _ newPlacement: (NotesTransaction) throws -> (parentId: UUID?, sortKey: FractionalSortKey)
    ) throws {
        let old = try perform { transaction in
            guard let page = try transaction.page(pageId) else { throw NotesStoreError.pageNotFound(pageId) }
            let placement = try newPlacement(transaction)
            var moved = page
            moved.parentId = placement.parentId
            moved.sortKey = placement.sortKey
            try transaction.updatePage(moved)
            if page.parentId != placement.parentId {
                if let oldParentId = page.parentId {
                    try Self.removeLinks(to: pageId, in: oldParentId, transaction)
                }
                if let newParentId = placement.parentId {
                    try Self.appendLink(to: pageId, in: newParentId, transaction)
                }
            }
            return (page.parentId, page.sortKey)
        }
        registerUndo(actionName) { operations in
            try operations.place(pageId, actionName: actionName) { _ in old }
        }
    }

    /// Одна транзакция; после неё — набор затронутых страниц для окна.
    @discardableResult
    private func perform<T>(_ body: (NotesTransaction) throws -> T) throws -> T {
        var touched: Set<UUID> = []
        let result = try store.write { transaction in
            let result = try body(transaction)
            let changes = transaction.changes
            touched.formUnion(changes.pages.map(\.page.id))
            touched.formUnion(changes.erasedPageIds)
            for change in changes.blocks {
                switch change {
                case .saved(let block, _, _): touched.insert(block.pageId)
                case .erased(_, let pageId): touched.insert(pageId)
                }
            }
            return result
        }
        onChange?(touched)
        return result
    }

    private func registerUndo(_ actionName: String, _ inverse: @escaping @MainActor (PageTreeOperations) throws -> Void) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { operations in
            MainActor.assumeIsolated {
                do {
                    try inverse(operations)
                } catch {
                    operations.onUndoFailure?(error)
                }
            }
        }
        undoManager.setActionName(actionName)
    }

    private static func appendLink(to pageId: UUID, in parentId: UUID, _ transaction: NotesTransaction) throws {
        let blocks = try transaction.blocks(ofPage: parentId)
        guard !blocks.contains(where: { $0.linkedPageId == pageId }) else { return }
        try transaction.insertBlock(Block(
            pageId: parentId, kind: .pageLink, linkedPageId: pageId, sortKey: .between(blocks.last?.sortKey, nil)
        ))
    }

    private static func removeLinks(to pageId: UUID, in parentId: UUID, _ transaction: NotesTransaction) throws {
        for block in try transaction.blocks(ofPage: parentId) where block.kind == .pageLink && block.linkedPageId == pageId {
            try transaction.deleteBlock(block.id)
        }
    }

    private static func erase(_ pages: [Page], _ transaction: NotesTransaction) throws {
        let erasedIds = Set(pages.map(\.id))
        for page in pages {
            if let parentId = page.parentId, !erasedIds.contains(parentId), try transaction.page(parentId) != nil {
                try removeLinks(to: page.id, in: parentId, transaction)
            }
        }
        for page in pages {
            try transaction.erasePage(page.id)
        }
    }
}
