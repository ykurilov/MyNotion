import Foundation
import GRDB
import Testing
@testable import NotesCore

@MainActor
@Suite("Операции с деревом страниц")
struct PageTreeOperationsTests {
    let folder: TemporaryFolder
    let wall = AdjustableWallClock(millis: 1_000)
    let store: NotesStore
    let tree: PageTreeOperations

    init() throws {
        folder = try TemporaryFolder()
        let clock = HybridLogicalClock(deviceId: UUID(), wallClock: wall.reading)
        store = try NotesStore(database: AppDatabase.open(at: folder.databaseURL), clock: clock)
        tree = PageTreeOperations(store: store)
    }

    private func rootPage(_ title: String) throws -> Page {
        try store.write { try $0.createPage(title: title) }
    }

    private func page(_ id: UUID) throws -> Page {
        try #require(try store.pageOutline().first { $0.id == id })
    }

    private func links(in pageId: UUID) throws -> [UUID] {
        try #require(try store.pageContent(pageId)).blocks.filter { $0.kind == .pageLink }.compactMap(\.linkedPageId)
    }

    // MARK: Подстраница (сценарий 2.1)

    @Test("Подстраница — пара: страница с parentId и блок-ссылка в родителе")
    func subpageIsPageAndLinkBlock() throws {
        let projects = try rootPage("Проекты")

        let subpage = try tree.createSubpage(in: projects.id, title: "MyNotion")

        #expect(try page(subpage.id).parentId == projects.id)
        #expect(try links(in: projects.id) == [subpage.id])
        #expect(try store.pageTree().children(of: projects.id).map(\.id) == [subpage.id])
    }

    @Test("Вторая подстраница встаёт после первой и в дереве, и в родителе")
    func subpagesKeepOrder() throws {
        let projects = try rootPage("Проекты")
        let first = try tree.createSubpage(in: projects.id, title: "Первая")
        let second = try tree.createSubpage(in: projects.id, title: "Вторая")

        #expect(try store.pageTree().children(of: projects.id).map(\.id) == [first.id, second.id])
        #expect(try links(in: projects.id) == [first.id, second.id])
    }

    @Test("Подстраница в несуществующей странице не создаётся")
    func subpageNeedsParent() throws {
        #expect(throws: NotesStoreError.pageNotFound(UUID(uuidString: "00000000-0000-7000-8000-0000000000AA")!)) {
            try tree.createSubpage(in: UUID(uuidString: "00000000-0000-7000-8000-0000000000AA")!)
        }
        #expect(try store.pageOutline().isEmpty)
    }

    @Test("Подписчик видит подстраницу и ссылку одной транзакцией")
    func subpageIsOneTransaction() throws {
        let projects = try rootPage("Проекты")
        let recorder = RecordingHook()
        store.addWriteHook(recorder)

        let subpage = try tree.createSubpage(in: projects.id)

        let transactions = recorder.transactions
        #expect(transactions.count == 1)
        #expect(transactions.first?.pages.contains { $0.page.id == subpage.id && $0.isNew } == true)
        #expect(transactions.first?.blocks.contains { change in
            if case .saved(let block, _, true) = change { block.pageId == projects.id && block.linkedPageId == subpage.id } else { false }
        } == true)
    }

    // MARK: Переименование

    @Test("Переименование меняет только название")
    func renameChangesTitle() throws {
        let projects = try rootPage("Проекты")
        try tree.rename(projects.id, to: "Дела")
        #expect(try page(projects.id).title == "Дела")
        #expect(try page(projects.id).sortKey == projects.sortKey)
    }

    // MARK: Перенос (сценарий 2.2)

    @Test("Ветка переезжает целиком: подстраницы остаются внутри, ссылка — у нового родителя")
    func moveCarriesBranch() throws {
        let projects = try rootPage("Проекты")
        let archive = try rootPage("Архив")
        let app = try tree.createSubpage(in: projects.id, title: "Приложение")
        let notes = try tree.createSubpage(in: app.id, title: "Заметки")

        try tree.move(app.id, toParent: archive.id, at: 0)

        let snapshot = try store.pageTree()
        #expect(snapshot.children(of: archive.id).map(\.id) == [app.id])
        #expect(snapshot.children(of: app.id).map(\.id) == [notes.id])
        #expect(snapshot.children(of: projects.id).isEmpty)
        #expect(try links(in: projects.id).isEmpty)
        #expect(try links(in: archive.id) == [app.id])
    }

    @Test("Перенос рядом: страница встаёт на указанное место среди соседей")
    func moveBetweenSiblings() throws {
        let first = try rootPage("Первая")
        let second = try rootPage("Вторая")
        let third = try rootPage("Третья")

        try tree.move(third.id, toParent: nil, at: 0)
        #expect(try store.pageTree().children(of: nil).map(\.id) == [third.id, first.id, second.id])

        try tree.move(third.id, toParent: nil, at: 2)
        #expect(try store.pageTree().children(of: nil).map(\.id) == [first.id, second.id, third.id])

        try tree.move(first.id, toParent: nil, at: 1)
        #expect(try store.pageTree().children(of: nil).map(\.id) == [second.id, first.id, third.id])
    }

    @Test("Перенос в корень убирает ссылку из прежнего родителя")
    func moveToRootRemovesLink() throws {
        let projects = try rootPage("Проекты")
        let app = try tree.createSubpage(in: projects.id, title: "Приложение")

        try tree.move(app.id, toParent: nil, at: 0)

        #expect(try page(app.id).parentId == nil)
        #expect(try links(in: projects.id).isEmpty)
    }

    @Test("Перенос внутрь своего потомка или в себя отклоняется, дерево не меняется")
    func moveIntoDescendantIsRejected() throws {
        let projects = try rootPage("Проекты")
        let app = try tree.createSubpage(in: projects.id, title: "Приложение")
        let notes = try tree.createSubpage(in: app.id, title: "Заметки")

        #expect(throws: NotesStoreError.self) { try tree.move(projects.id, toParent: notes.id, at: 0) }
        #expect(throws: NotesStoreError.self) { try tree.move(projects.id, toParent: projects.id, at: 0) }
        #expect(!(try tree.canMove(projects.id, toParent: notes.id)))
        #expect(try tree.canMove(notes.id, toParent: nil))

        #expect(try page(projects.id).parentId == nil)
        #expect(try links(in: notes.id).isEmpty)
        #expect(try links(in: app.id) == [notes.id])
    }

    // MARK: Корзина (сценарий 2.3)

    @Test("Удаление уводит ветку в корзину: в дереве её нет, в корзине — одна запись")
    func trashHidesBranch() throws {
        let projects = try rootPage("Проекты")
        let app = try tree.createSubpage(in: projects.id, title: "Приложение")
        _ = try tree.createSubpage(in: app.id, title: "Заметки")

        try tree.moveToTrash(app.id)

        let snapshot = try store.pageTree()
        #expect(snapshot.children(of: projects.id).isEmpty)
        #expect(snapshot.visiblePageCount == 1)
        #expect(try store.trashEntries().map(\.id) == [app.id])
        #expect(try links(in: projects.id).isEmpty)
    }

    @Test("Возврат ставит ветку на прежнее место вместе с подстраницами и ссылкой")
    func restorePutsBranchBack() throws {
        let projects = try rootPage("Проекты")
        let before = try tree.createSubpage(in: projects.id, title: "До")
        let app = try tree.createSubpage(in: projects.id, title: "Приложение")
        let after = try tree.createSubpage(in: projects.id, title: "После")
        let notes = try tree.createSubpage(in: app.id, title: "Заметки")

        try tree.moveToTrash(app.id)
        try tree.restore(app.id)

        let snapshot = try store.pageTree()
        #expect(snapshot.children(of: projects.id).map(\.id) == [before.id, app.id, after.id])
        #expect(snapshot.children(of: app.id).map(\.id) == [notes.id])
        #expect(try store.trashEntries().isEmpty)
        #expect(Set(try links(in: projects.id)) == [before.id, app.id, after.id])
    }

    @Test("Если родитель исчез, возврат ставит страницу в корень")
    func restoreWithoutParentGoesToRoot() throws {
        let projects = try rootPage("Проекты")
        let app = try tree.createSubpage(in: projects.id, title: "Приложение")
        try tree.moveToTrash(app.id)
        try tree.moveToTrash(projects.id)
        try tree.deleteForever(projects.id)

        try tree.restore(app.id)

        #expect(try page(app.id).parentId == nil)
        #expect(try store.pageTree().children(of: nil).map(\.id) == [app.id])
    }

    @Test("Страница с удалённым родителем без возврата видна в корне")
    func orphanIsShownInRoot() throws {
        let projects = try rootPage("Проекты")
        let app = try tree.createSubpage(in: projects.id, title: "Приложение")
        try store.database.dbWriter.write { db in
            try db.execute(sql: "DELETE FROM page WHERE id = ?", arguments: [projects.id.databaseText])
        }
        #expect(try store.pageTree().children(of: nil).map(\.id) == [app.id])
    }

    // MARK: Удаление навсегда

    @Test("Удаление навсегда стирает ветку с блоками и оставляет надгробия (id + метка часов)")
    func deleteForeverLeavesTombstones() throws {
        let projects = try rootPage("Проекты")
        let app = try tree.createSubpage(in: projects.id, title: "Приложение")
        let notes = try tree.createSubpage(in: app.id, title: "Заметки")
        try tree.moveToTrash(app.id)
        wall.set(5_000)

        try tree.deleteForever(app.id)

        #expect(try store.pageOutline().map(\.id) == [projects.id])
        #expect(try store.pageContent(notes.id) == nil)
        let blockCount = try store.database.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM block WHERE pageId IN (?, ?)",
                             arguments: [app.id.databaseText, notes.id.databaseText])
        }
        #expect(blockCount == 0)
        let tombstones = try store.pageTombstones()
        #expect(Set(tombstones.map(\.pageId)) == [app.id, notes.id])
        #expect(tombstones.allSatisfy { $0.erasedAt.wallMillis == 5_000 && $0.erasedAt.deviceId == store.clock.deviceId })
        #expect(try store.trashEntries().isEmpty)
    }

    @Test("Удалить навсегда можно только из корзины")
    func deleteForeverOnlyFromTrash() throws {
        let projects = try rootPage("Проекты")
        #expect(throws: NotesStoreError.self) { try tree.deleteForever(projects.id) }
        #expect(try store.pageOutline().map(\.id) == [projects.id])
    }

    @Test("Подписчик узнаёт о стёртых страницах в той же транзакции")
    func hookSeesErasedPages() throws {
        let projects = try rootPage("Проекты")
        let app = try tree.createSubpage(in: projects.id, title: "Приложение")
        try tree.moveToTrash(projects.id)
        let recorder = RecordingHook()
        store.addWriteHook(recorder)

        try tree.deleteForever(projects.id)

        #expect(recorder.transactions.count == 1)
        #expect(Set(recorder.transactions.first?.erasedPageIds ?? []) == [projects.id, app.id])
    }

    @Test("Очистка корзины стирает все записи корзины одной транзакцией")
    func emptyTrashErasesEverything() throws {
        let first = try rootPage("Первая")
        let second = try rootPage("Вторая")
        let kept = try rootPage("Остаётся")
        try tree.moveToTrash(first.id)
        try tree.moveToTrash(second.id)
        let recorder = RecordingHook()
        store.addWriteHook(recorder)

        try tree.emptyTrash()

        #expect(recorder.transactions.count == 1)
        #expect(try store.pageOutline().map(\.id) == [kept.id])
        #expect(Set(try store.pageTombstones().map(\.pageId)) == [first.id, second.id])
    }

    // MARK: Отмена и возврат (FR-012)

    @discardableResult
    private func undoable<T>(_ undoManager: UndoManager, _ action: () throws -> T) rethrows -> T {
        undoManager.beginUndoGrouping()
        defer { undoManager.endUndoGrouping() }
        return try action()
    }

    private func makeUndoManager() -> UndoManager {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        tree.undoManager = undoManager
        return undoManager
    }

    @Test("⌘Z и ⇧⌘Z для переноса ветки")
    func undoRedoMove() throws {
        let undoManager = makeUndoManager()
        let projects = try rootPage("Проекты")
        let archive = try rootPage("Архив")
        let app = try undoable(undoManager) { try tree.createSubpage(in: projects.id, title: "Приложение") }
        try undoable(undoManager) { try tree.move(app.id, toParent: archive.id, at: 0) }

        undoManager.undo()
        #expect(try page(app.id).parentId == projects.id)
        #expect(try page(app.id).sortKey == app.sortKey)
        #expect(try links(in: projects.id) == [app.id])
        #expect(try links(in: archive.id).isEmpty)

        undoManager.redo()
        #expect(try page(app.id).parentId == archive.id)
        #expect(try links(in: archive.id) == [app.id])
    }

    @Test("⌘Z для переименования и удаления в корзину")
    func undoRenameAndTrash() throws {
        let undoManager = makeUndoManager()
        let projects = try rootPage("Проекты")

        try undoable(undoManager) { try tree.rename(projects.id, to: "Дела") }
        try undoable(undoManager) { try tree.moveToTrash(projects.id) }

        undoManager.undo()
        #expect(try store.trashEntries().isEmpty)
        #expect(try page(projects.id).title == "Дела")
        undoManager.undo()
        #expect(try page(projects.id).title == "Проекты")
        undoManager.redo()
        undoManager.redo()
        #expect(try store.trashEntries().map(\.id) == [projects.id])
    }

    @Test("⌘Z для новой подстраницы уводит её в корзину, ничего не стирая; ⇧⌘Z возвращает")
    func undoCreateSubpage() throws {
        let undoManager = makeUndoManager()
        let projects = try rootPage("Проекты")
        let app = try undoable(undoManager) { try tree.createSubpage(in: projects.id, title: "Приложение") }

        undoManager.undo()
        #expect(try store.pageTree().children(of: projects.id).isEmpty)
        #expect(try links(in: projects.id).isEmpty)

        undoManager.redo()
        #expect(try store.pageTree().children(of: projects.id).map(\.id) == [app.id])
        #expect(try links(in: projects.id) == [app.id])
    }

    @Test("После операции приходит набор затронутых страниц")
    func reportsTouchedPages() throws {
        let projects = try rootPage("Проекты")
        var reported: [Set<UUID>] = []
        tree.onChange = { reported.append($0) }

        let app = try tree.createSubpage(in: projects.id)

        #expect(reported == [[projects.id, app.id]])
    }
}

/// Подписчик, который запоминает, что пришло в каждой транзакции.
final class RecordingHook: NotesWriteHook, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [NotesChanges] = []

    var transactions: [NotesChanges] { lock.withLock { recorded } }

    func notesWillCommit(_ changes: NotesChanges, in transaction: NotesTransaction) throws {
        lock.withLock { recorded.append(changes) }
    }
}
