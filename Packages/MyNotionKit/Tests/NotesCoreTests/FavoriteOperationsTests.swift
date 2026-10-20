import Foundation
import Testing
@testable import NotesCore

/// Избранное: добавить, убрать, переставить, корзина, удаление навсегда; ⌘Z каждого
/// (contracts/page-operations.md, «Избранное»).
@MainActor
@Suite("Избранное: операции")
struct FavoriteOperationsTests {
    let folder: TemporaryFolder
    let store: NotesStore
    let tree: PageTreeOperations
    let undoManager = UndoManager()

    init() throws {
        folder = try TemporaryFolder()
        store = try NotesStore(database: AppDatabase.open(at: folder.databaseURL), clock: HybridLogicalClock(deviceId: UUID()))
        tree = PageTreeOperations(store: store)
    }

    private func rootPage(_ title: String) throws -> Page {
        try store.write { try $0.createPage(title: title) }
    }

    private func page(_ id: UUID) throws -> Page {
        try #require(try store.pageOutline().first { $0.id == id })
    }

    private func favoriteIds() throws -> [UUID] {
        try store.favoritePages().map(\.id)
    }

    /// Отмена окна включается только в тестах отмены: без открытой группы `UndoManager` не принимает записи.
    private func undoable<T>(_ action: () throws -> T) rethrows -> T {
        undoManager.groupsByEvent = false
        tree.undoManager = undoManager
        undoManager.beginUndoGrouping()
        defer { undoManager.endUndoGrouping() }
        return try action()
    }

    @Test("Добавление ставит страницу в конец избранного")
    func addGoesToTheEnd() throws {
        let a = try rootPage("A"), b = try rootPage("B"), c = try rootPage("C")
        try tree.addToFavorites(b.id)
        try tree.addToFavorites(a.id)
        try tree.addToFavorites(c.id)
        #expect(try favoriteIds() == [b.id, a.id, c.id])
    }

    @Test("Повторное добавление ничего не меняет, ключ прежний")
    func addingTwiceKeepsKey() throws {
        let a = try rootPage("A"), b = try rootPage("B")
        try tree.addToFavorites(a.id)
        try tree.addToFavorites(b.id)
        let key = try page(a.id).favorite
        try tree.addToFavorites(a.id)
        #expect(try page(a.id).favorite == key)
        #expect(try favoriteIds() == [a.id, b.id])
    }

    @Test("Убрать — favorite пусто, остальные на месте")
    func removeClearsKey() throws {
        let a = try rootPage("A"), b = try rootPage("B")
        try tree.addToFavorites(a.id)
        try tree.addToFavorites(b.id)
        try tree.removeFromFavorites(a.id)
        #expect(try page(a.id).favorite == nil)
        #expect(try favoriteIds() == [b.id])
    }

    @Test("Перестановка меняет ключ только у перетащенной строки")
    func moveChangesOnlyDraggedKey() throws {
        let a = try rootPage("A"), b = try rootPage("B"), c = try rootPage("C")
        for p in [a, b, c] { try tree.addToFavorites(p.id) }
        let before = try [a, b, c].map { try page($0.id).favorite }
        try tree.moveFavorite(c.id, toIndex: 0)
        #expect(try favoriteIds() == [c.id, a.id, b.id])
        #expect(try page(a.id).favorite == before[0])
        #expect(try page(b.id).favorite == before[1])
        #expect(try page(c.id).favorite != before[2])
        try tree.moveFavorite(c.id, toIndex: 1)
        #expect(try favoriteIds() == [a.id, c.id, b.id])
        try tree.moveFavorite(a.id, toIndex: 2)
        #expect(try favoriteIds() == [c.id, b.id, a.id])
    }

    @Test("Перестановка: индекс за краем — в конец, страница не из избранного — ошибка")
    func moveEdges() throws {
        let a = try rootPage("A"), b = try rootPage("B"), outsider = try rootPage("Не в избранном")
        try tree.addToFavorites(a.id)
        try tree.addToFavorites(b.id)
        try tree.moveFavorite(a.id, toIndex: 99)
        #expect(try favoriteIds() == [b.id, a.id])
        #expect(throws: (any Error).self) { try tree.moveFavorite(outsider.id, toIndex: 0) }
    }

    @Test("Избранное не меняет «изменено» страницы")
    func favoriteDoesNotTouchUpdatedAt() throws {
        let a = try rootPage("A")
        let updatedAt = try page(a.id).updatedAt
        try tree.addToFavorites(a.id)
        try tree.removeFromFavorites(a.id)
        #expect(try page(a.id).updatedAt == updatedAt)
    }

    @Test("Корзина прячет страницу из избранного и вместе с подстраницей; возврат возвращает на место")
    func trashHidesAndRestoreReturns() throws {
        let a = try rootPage("A"), b = try rootPage("B"), c = try rootPage("C")
        for p in [a, b, c] { try tree.addToFavorites(p.id) }
        let child = try tree.createSubpage(in: b.id, title: "Внутри")
        try tree.addToFavorites(child.id)
        try tree.moveToTrash(b.id)
        #expect(try favoriteIds() == [a.id, c.id])
        #expect(try page(b.id).favorite != nil, "поле в корзине сохраняется")
        try tree.restore(b.id)
        #expect(try favoriteIds() == [a.id, b.id, c.id, child.id])
    }

    @Test("Удаление навсегда — строки в избранном нет")
    func deleteForeverRemovesRow() throws {
        let a = try rootPage("A"), b = try rootPage("B")
        try tree.addToFavorites(a.id)
        try tree.addToFavorites(b.id)
        try tree.moveToTrash(a.id)
        try tree.deleteForever(a.id)
        #expect(try favoriteIds() == [b.id])
    }

    @Test("⌘Z добавления и возврат ⇧⌘Z")
    func undoAdd() throws {
        let a = try rootPage("A")
        try undoable { try tree.addToFavorites(a.id) }
        let key = try page(a.id).favorite
        undoManager.undo()
        #expect(try favoriteIds().isEmpty)
        undoManager.redo()
        #expect(try favoriteIds() == [a.id])
        #expect(try page(a.id).favorite == key)
    }

    @Test("⌘Z удаления из избранного — на прежнее место")
    func undoRemove() throws {
        let a = try rootPage("A"), b = try rootPage("B"), c = try rootPage("C")
        for p in [a, b, c] { try tree.addToFavorites(p.id) }
        let key = try page(b.id).favorite
        try undoable { try tree.removeFromFavorites(b.id) }
        #expect(try favoriteIds() == [a.id, c.id])
        undoManager.undo()
        #expect(try favoriteIds() == [a.id, b.id, c.id])
        #expect(try page(b.id).favorite == key)
    }

    @Test("⌘Z перестановки — прежний ключ")
    func undoMove() throws {
        let a = try rootPage("A"), b = try rootPage("B"), c = try rootPage("C")
        for p in [a, b, c] { try tree.addToFavorites(p.id) }
        let key = try page(c.id).favorite
        try undoable { try tree.moveFavorite(c.id, toIndex: 0) }
        undoManager.undo()
        #expect(try favoriteIds() == [a.id, b.id, c.id])
        #expect(try page(c.id).favorite == key)
    }
}
