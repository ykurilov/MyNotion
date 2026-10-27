import Foundation
import NotesCore
import PhoneShell
import Testing

/// Дерево страниц на iPhone: верхний уровень, подстраницы, новые страницы; корзины и шаблонов не видно.
@MainActor
@Suite("iPhone: дерево страниц")
struct PageBrowserTests {
    let library: TemporaryLibrary

    init() throws {
        library = try TemporaryLibrary()
    }

    @Test("Верхний уровень и подстраницы — по порядку, как на Mac")
    func listsLevels() throws {
        let operations = PageTreeOperations(store: library.store)
        let work = try operations.createRootPage(title: "Работа")
        let home = try operations.createRootPage(title: "Дом")
        let plans = try operations.createSubpage(in: work.id, title: "Планы")
        let browser = PageBrowser(store: library.store)
        #expect(browser.children(of: nil).map(\.title) == ["Работа", "Дом"])
        #expect(browser.children(of: work.id).map(\.id) == [plans.id])
        #expect(browser.hasChildren(work.id))
        #expect(!browser.hasChildren(home.id))
    }

    @Test("Страницы в корзине и шаблоны не показываются")
    func hidesTrashAndTemplates() throws {
        let operations = PageTreeOperations(store: library.store)
        let kept = try operations.createRootPage(title: "Живая")
        let trashed = try operations.createRootPage(title: "В корзине")
        let template = try operations.createRootPage(title: "Шаблон")
        let inside = try operations.createSubpage(in: kept.id, title: "Удалённая подстраница")
        try operations.moveToTrash(trashed.id)
        try operations.moveToTrash(inside.id)
        try operations.makeTemplate(template.id)
        let browser = PageBrowser(store: library.store)
        #expect(browser.children(of: nil).map(\.title) == ["Живая"])
        #expect(!browser.hasChildren(kept.id))
        #expect(browser.page(trashed.id) == nil)
        #expect(!browser.isAvailable(trashed.id))
        #expect(browser.isAvailable(kept.id))
    }

    @Test("«+» на верхнем уровне: новая страница последней, дерево обновлено")
    func createsRootPage() throws {
        try PageTreeOperations(store: library.store).createRootPage(title: "Первая")
        let browser = PageBrowser(store: library.store)
        let revision = browser.revision
        let created = try browser.createPage(in: nil)
        #expect(browser.children(of: nil).map(\.id).last == created.id)
        #expect(browser.revision > revision)
        #expect(created.title.isEmpty)
    }

    @Test("«+» внутри страницы: подстраница со ссылкой в конце родителя")
    func createsSubpage() throws {
        let parent = try PageTreeOperations(store: library.store).createRootPage(title: "Родитель")
        let browser = PageBrowser(store: library.store)
        let created = try browser.createPage(in: parent.id)
        #expect(browser.children(of: parent.id).map(\.id) == [created.id])
        let links = try #require(try library.store.pageContent(parent.id)).blocks.filter { $0.kind == .pageLink }
        #expect(links.map(\.linkedPageId) == [created.id])
    }

    @Test("Правки извне (синхронизация) видны после перечитывания")
    func reloadsAfterExternalChange() throws {
        let browser = PageBrowser(store: library.store)
        #expect(browser.children(of: nil).isEmpty)
        try library.store.write { try $0.createPage(title: "С Mac") }
        let revision = browser.revision
        browser.reload()
        #expect(browser.children(of: nil).map(\.title) == ["С Mac"])
        #expect(browser.revision > revision)
    }

    @Test("Путь к странице: предки от корня")
    func ancestors() throws {
        let operations = PageTreeOperations(store: library.store)
        let root = try operations.createRootPage(title: "Корень")
        let middle = try operations.createSubpage(in: root.id, title: "Середина")
        let leaf = try operations.createSubpage(in: middle.id, title: "Лист")
        let browser = PageBrowser(store: library.store)
        #expect(browser.ancestors(of: leaf.id).map(\.title) == ["Корень", "Середина"])
    }

    @Test("«+» в открытой странице: открытый родитель принимает ссылку на подстраницу и не затирает её своим сохранением")
    func openParentAdoptsSubpageLink() throws {
        let parent = try PageTreeOperations(store: library.store).createRootPage(title: "Родитель")
        let openDocuments = OpenDocuments(store: library.store)
        let document = try openDocuments.open(parent.id)
        let browser = PageBrowser(store: library.store, openDocuments: openDocuments)
        let firstBlock = try #require(document.blocks.first)
        document.setText(InlineText("набрано до «+»"), ofBlock: firstBlock.id)

        let child = try browser.createPage(in: parent.id)

        #expect(document.blocks.contains { $0.kind == .pageLink && $0.linkedPageId == child.id })
        document.setText(InlineText("набрано после «+»"), ofBlock: firstBlock.id)
        #expect(openDocuments.saveAll())
        let stored = try #require(try library.store.pageContent(parent.id))
        #expect(stored.blocks.contains { $0.kind == .pageLink && $0.linkedPageId == child.id })
        #expect(stored.blocks.contains { $0.text.string == "набрано после «+»" })
    }
}
