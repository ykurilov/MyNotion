import Foundation

/// Избранное (research R4, contracts/page-operations.md): страница в избранном — если у неё есть ключ `favorite`.
/// Порядок — по ключу; перестановка меняет ключ только у перетащенной страницы. Корзина прячет страницу, поле остаётся.
extension PageTreeOperations {
    /// В конец избранного. Уже в избранном — ничего не меняется.
    public func addToFavorites(_ pageId: UUID) throws {
        let added = try perform { transaction in
            guard var page = try transaction.page(pageId) else { throw NotesStoreError.pageNotFound(pageId) }
            guard page.favorite == nil else { return false }
            let lastKey = try transaction.allPages().compactMap(\.favorite).max()
            page.favorite = .between(lastKey, nil)
            try transaction.updatePage(page)
            return true
        }
        guard added else { return }
        registerUndo("Добавление в избранное") { try $0.removeFromFavorites(pageId) }
    }

    /// Убрать из избранного. Отмена возвращает прежний ключ, то есть прежнее место.
    public func removeFromFavorites(_ pageId: UUID) throws {
        let oldKey = try perform { transaction -> FractionalSortKey? in
            guard var page = try transaction.page(pageId) else { throw NotesStoreError.pageNotFound(pageId) }
            guard let oldKey = page.favorite else { return nil }
            page.favorite = nil
            try transaction.updatePage(page)
            return oldKey
        }
        guard let oldKey else { return }
        registerUndo("Удаление из избранного") { try $0.setFavoriteKey(oldKey, of: pageId, actionName: "Добавление в избранное") }
    }

    /// Поставить избранную страницу на место `index` среди остальных видимых избранных (за краем — в конец).
    public func moveFavorite(_ pageId: UUID, toIndex index: Int) throws {
        let oldKey = try perform { transaction -> FractionalSortKey in
            let all = try transaction.allPages()
            guard let page = all.first(where: { $0.id == pageId }), let oldKey = page.favorite else {
                throw NotesStoreError.invalidPage("страницы нет в избранном")
            }
            let byId = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
            let others = all
                .filter { $0.id != pageId && $0.favorite != nil && !PageTreeSnapshot.isInTrash($0, pagesById: byId) }
                .sorted { $0.favorite! < $1.favorite! }
            let position = min(max(index, 0), others.count)
            let previous = position > 0 ? others[position - 1].favorite : nil
            var next = position < others.count ? others[position].favorite : nil
            if let previous, let nextKey = next, !(previous < nextKey) { next = nil }
            var moved = page
            moved.favorite = .between(previous, next)
            try transaction.updatePage(moved)
            return oldKey
        }
        registerUndo("Перестановка избранного") { try $0.setFavoriteKey(oldKey, of: pageId, actionName: "Перестановка избранного") }
    }

    /// Вернуть точный ключ (отмена и её повтор): место и принадлежность избранному — как были.
    private func setFavoriteKey(_ key: FractionalSortKey?, of pageId: UUID, actionName: String) throws {
        let oldKey = try perform { transaction -> FractionalSortKey? in
            guard var page = try transaction.page(pageId) else { throw NotesStoreError.pageNotFound(pageId) }
            let oldKey = page.favorite
            page.favorite = key
            try transaction.updatePage(page)
            return oldKey
        }
        registerUndo(actionName) { try $0.setFavoriteKey(oldKey, of: pageId, actionName: actionName) }
    }
}
