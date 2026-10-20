import Foundation
import Testing
@testable import NotesCore

/// Шаблоны (contracts/page-operations.md, «Шаблоны», R12): «Сделать шаблоном» уводит страницу в корень, убирает ссылку
/// в прежнем родителе и ставит отметку одной правкой; «Перестать быть шаблоном» снимает отметку; ⌘Z возвращает всё как
/// было, в том числе ссылку на прежнем месте; шаблон в корзине в списке шаблонов не предлагается.
@MainActor
@Suite("Шаблоны: сделать и перестать")
struct TemplateOperationsTests {
    let folder: TemporaryFolder
    let store: NotesStore
    let tree: PageTreeOperations

    init() throws {
        folder = try TemporaryFolder()
        store = try NotesStore(database: AppDatabase.open(at: folder.databaseURL), clock: HybridLogicalClock(deviceId: UUID()))
        tree = PageTreeOperations(store: store)
    }

    /// Родитель «Проекты» со ссылками на «Альфа», «Бета»; у «Альфа» — подстраница «Внутри».
    private func projects() throws -> (parent: Page, alpha: Page, beta: Page, inner: Page) {
        try store.write { tx in
            let parent = try tx.createPage(title: "Проекты")
            let alpha = try tx.createPage(title: "Альфа", parentId: parent.id)
            let beta = try tx.createPage(title: "Бета", parentId: parent.id)
            let inner = try tx.createPage(title: "Внутри", parentId: alpha.id)
            for block in try tx.blocks(ofPage: parent.id) { try tx.deleteBlock(block.id) }
            var key: FractionalSortKey?
            for linked in [alpha.id, beta.id] {
                key = .between(key, nil)
                try tx.insertBlock(Block(pageId: parent.id, kind: .pageLink, linkedPageId: linked, sortKey: key!))
            }
            let first = try #require(try tx.blocks(ofPage: alpha.id).first)
            try tx.insertBlock(Block(pageId: alpha.id, kind: .pageLink, linkedPageId: inner.id, sortKey: .between(first.sortKey, nil)))
            return (parent, alpha, beta, inner)
        }
    }

    private func linkTitles(_ pageId: UUID) throws -> [String] {
        let titles = Dictionary(uniqueKeysWithValues: try store.pageOutline().map { ($0.id, $0.title) })
        return try #require(try store.pageContent(pageId)).blocks.compactMap { $0.kind == .pageLink ? $0.linkedPageId.flatMap { titles[$0] } : nil }
    }

    private func page(_ id: UUID) throws -> Page { try #require(try store.pageTree().page(id)) }

    private func makeUndoManager() -> UndoManager {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        tree.undoManager = undoManager
        return undoManager
    }

    @Test("Сделать шаблоном: страница в корне последней, отметка стоит, ссылка в прежнем родителе убрана, подстраницы при ней")
    func makeTemplateMovesToRootAndRemovesLink() throws {
        let (parent, alpha, _, inner) = try projects()
        let lastRoot = try #require(try store.pageTree().children(of: nil).last)

        try tree.makeTemplate(alpha.id)

        let template = try page(alpha.id)
        #expect(template.isTemplate)
        #expect(template.parentId == nil)
        #expect(template.sortKey > lastRoot.sortKey)
        #expect(try linkTitles(parent.id) == ["Бета"])
        #expect(try page(inner.id).parentId == alpha.id)
        #expect(try linkTitles(alpha.id) == ["Внутри"])
        #expect(try store.templatePages().map(\.id) == [alpha.id])
    }

    @Test("Страница верхнего уровня: остаётся в корне, ссылок не трогаем")
    func rootPageBecomesTemplateInPlace() throws {
        let (parent, _, _, _) = try projects()

        try tree.makeTemplate(parent.id)

        #expect(try page(parent.id).isTemplate)
        #expect(try page(parent.id).parentId == nil)
        #expect(try linkTitles(parent.id) == ["Альфа", "Бета"])
    }

    @Test("⌘Z «Сделать шаблоном»: прежний родитель, место и ссылка на прежнем месте (тот же блок); повтор — снова шаблон")
    func undoRestoresParentAndLink() throws {
        let (parent, alpha, beta, _) = try projects()
        let undoManager = makeUndoManager()
        let linksBefore = try store.pageContent(parent.id)!.blocks

        undoManager.beginUndoGrouping()
        try tree.makeTemplate(alpha.id)
        undoManager.endUndoGrouping()
        undoManager.undo()

        let restored = try page(alpha.id)
        #expect(!restored.isTemplate)
        #expect(restored.parentId == parent.id)
        #expect(restored.sortKey == alpha.sortKey)
        #expect(try linkTitles(parent.id) == ["Альфа", "Бета"])
        #expect(try store.pageContent(parent.id)!.blocks.map(\.id) == linksBefore.map(\.id), "ссылка — тот же блок на прежнем месте")
        #expect(try store.templatePages().isEmpty)
        #expect(try page(beta.id).parentId == parent.id)

        undoManager.redo()
        #expect(try page(alpha.id).isTemplate)
        #expect(try page(alpha.id).parentId == nil)
        #expect(try linkTitles(parent.id) == ["Бета"])
    }

    @Test("Уже шаблон: ничего не меняется, отмены нет")
    func makingTemplateTwiceDoesNothing() throws {
        let (_, alpha, _, _) = try projects()
        try tree.makeTemplate(alpha.id)
        let undoManager = makeUndoManager()

        try tree.makeTemplate(alpha.id)

        #expect(!undoManager.canUndo)
    }

    @Test("Перестать быть шаблоном: отметка снята, страница остаётся в корне «Страниц»; ⌘Z — снова шаблон")
    func stopBeingTemplate() throws {
        let (_, alpha, _, _) = try projects()
        try tree.makeTemplate(alpha.id)
        let undoManager = makeUndoManager()

        undoManager.beginUndoGrouping()
        try tree.stopBeingTemplate(alpha.id)
        undoManager.endUndoGrouping()

        #expect(!(try page(alpha.id).isTemplate))
        #expect(try page(alpha.id).parentId == nil)
        #expect(try store.templatePages().isEmpty)

        undoManager.undo()
        #expect(try page(alpha.id).isTemplate)
        #expect(try store.templatePages().map(\.id) == [alpha.id])
    }

    @Test("Не шаблон: «Перестать быть шаблоном» ничего не делает, отмены нет")
    func stoppingNonTemplateDoesNothing() throws {
        let (_, alpha, _, _) = try projects()
        let undoManager = makeUndoManager()

        try tree.stopBeingTemplate(alpha.id)

        #expect(!undoManager.canUndo)
    }

    @Test("Список шаблонов: по порядку в корне; шаблон в корзине (сам или с предком) не предлагается; вернули — снова виден")
    func templateInTrashIsNotOffered() throws {
        let (_, alpha, beta, _) = try projects()
        try tree.makeTemplate(alpha.id)
        try tree.makeTemplate(beta.id)
        #expect(try store.templatePages().map(\.title) == ["Альфа", "Бета"])

        try tree.moveToTrash(alpha.id)
        #expect(try store.templatePages().map(\.title) == ["Бета"])

        try tree.restore(alpha.id)
        #expect(try store.templatePages().map(\.title) == ["Альфа", "Бета"])
    }

    @Test("Дерево «Страниц» без шаблонов и их подстраниц; список шаблонов — по порядку дерева")
    func treeWithoutTemplates() throws {
        let (parent, alpha, beta, inner) = try projects()
        try tree.makeTemplate(alpha.id)

        let snapshot = try store.pageTree()
        let visible = snapshot.withoutTemplates()

        #expect(snapshot.templates.map(\.id) == [alpha.id])
        #expect(visible.page(alpha.id) == nil && visible.page(inner.id) == nil)
        #expect(visible.page(parent.id) != nil && visible.page(beta.id) != nil)
        #expect(visible.children(of: nil).map(\.title) == ["Проекты"])
    }

    @Test("Страницы нет — ошибка")
    func missingPageThrows() throws {
        #expect(throws: NotesStoreError.self) { try tree.makeTemplate(UUID()) }
        #expect(throws: NotesStoreError.self) { try tree.stopBeingTemplate(UUID()) }
    }
}
