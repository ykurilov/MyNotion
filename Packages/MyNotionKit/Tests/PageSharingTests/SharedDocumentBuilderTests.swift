import Databases
import Foundation
import NotesCore
import Testing
@testable import PageSharing

/// Снимок для ссылки (contracts/share-api.md, «Снимок»): в нём только опубликованное, закрытое не утекает
/// ни названием, ни id, ни файлом.
@Suite("Снимок страницы для ссылки")
struct SharedDocumentBuilderTests {
    let library: SharingLibrary

    init() throws {
        library = try SharingLibrary()
    }

    private func build(includeSubpages: Bool, collapsed: Set<UUID> = []) throws -> SharePublication {
        let builder = SharedDocumentBuilder(store: library.store, collapsedBlockIds: { _ in collapsed })
        return try #require(try builder.build(rootPageId: library.root, includeSubpages: includeSubpages))
    }

    private func json(_ publication: SharePublication) -> String { String(decoding: publication.data, as: UTF8.self) }

    @Test("Без подстраниц: только сама страница и встроенная база; подстраница, упоминание и ссылка на неё закрыты")
    func withoutSubpagesNothingElseLeaks() throws {
        let publication = try build(includeSubpages: false)
        let ids = Set(publication.document.pages.map(\.id))
        #expect(ids == [library.root.shareKey, library.inlineDatabase.shareKey])
        let text = json(publication)
        for secret in ["Секретная подстраница", "Тайный текст", "Чужая страница", library.child.shareKey, library.child.uuidString,
                       library.privatePage.shareKey, library.grandchild.shareKey, "Закрытая картинка.png"] {
            #expect(!text.contains(secret), "в снимке нет «\(secret)»")
        }
        let root = try #require(publication.document.pages.first { $0.id == library.root.shareKey })
        let pageLink = try #require(root.blocks.first { $0.kind == "pageLink" })
        #expect(pageLink.page == SharedPageRef(id: nil))
        let mention = try #require(root.blocks.flatMap(\.text.runs).first { $0.style == "mention" })
        #expect(mention.pageId == nil)
        #expect(!root.blocks.flatMap(\.text.runs).contains { $0.style == "link" && $0.url?.hasPrefix("mynotion") == true })
    }

    @Test("Встроенная база без подстраниц — таблицей, строки без ссылок")
    func inlineDatabaseRowsAreLockedWithoutSubpages() throws {
        let database = try #require(try build(includeSubpages: false).document.pages.first { $0.id == library.inlineDatabase.shareKey }?.database)
        #expect(database.columns == ["Название", "Сайт"])
        #expect(database.rows.map(\.title) == ["Первая строка", "Вторая строка"])
        #expect(database.rows.map(\.cells) == [["Первая строка", "https://example.com"], ["Вторая строка", ""]])
        #expect(database.rows.allSatisfy { $0.pageId == nil })
    }

    @Test("С подстраницами: вся ветка без корзины и шаблонов, строки базы открываются, всё под корзиной закрыто")
    func withSubpagesWholeLiveBranch() throws {
        let publication = try build(includeSubpages: true)
        let ids = Set(publication.document.pages.map(\.id))
        #expect(ids.contains(library.child.shareKey))
        #expect(ids.contains(library.grandchild.shareKey))
        #expect(!ids.contains(library.trashed.shareKey))
        #expect(!ids.contains(library.underTrashed.shareKey))
        #expect(!ids.contains(library.template.shareKey))
        #expect(!ids.contains(library.privatePage.shareKey))
        let child = try #require(publication.document.pages.first { $0.id == library.child.shareKey })
        #expect(child.parentId == library.root.shareKey)
        let root = try #require(publication.document.pages.first { $0.id == library.root.shareKey })
        #expect(root.blocks.first { $0.kind == "pageLink" }?.page == SharedPageRef(id: library.child.shareKey))
        let database = try #require(publication.document.pages.first { $0.id == library.inlineDatabase.shareKey }?.database)
        #expect(database.rows.allSatisfy { $0.pageId != nil })
        #expect(!json(publication).contains("Чужая страница"))
    }

    @Test("Файлы — только из блоков снимка; тип для браузера из типа Apple")
    func filesOnlyFromPublishedBlocks() throws {
        let narrow = try build(includeSubpages: false)
        #expect(narrow.document.files.map(\.id) == [library.image.id.shareKey])
        #expect(narrow.document.files.first?.mimeType == "image/png")
        #expect(narrow.files.keys.sorted { $0.uuidString < $1.uuidString } == [library.image.id])
        let wide = try build(includeSubpages: true)
        #expect(Set(wide.document.files.map(\.id)) == [library.image.id.shareKey, library.childImage.id.shareKey])
    }

    @Test("Свёрнутые переключатели и заголовки, отметки, цвет и id строчными буквами")
    func blockStateIsCarried() throws {
        let publication = try build(includeSubpages: false, collapsed: [library.toggle])
        let root = try #require(publication.document.pages.first { $0.id == library.root.shareKey })
        let toggle = try #require(root.blocks.first { $0.id == library.toggle.shareKey })
        #expect(toggle.collapsed == true)
        #expect(root.blocks.first { $0.kind == "checkbox" }?.checked == true)
        let nested = try #require(root.blocks.first { $0.text.string == "Внутри переключателя" })
        #expect(nested.indent == 1)
        #expect(publication.document.rootPageId == library.root.uuidString.lowercased())
    }

    @Test("Одинаковая страница — одинаковый digest; правка меняет его")
    func digestFollowsContent() throws {
        let first = try build(includeSubpages: false)
        #expect(try build(includeSubpages: false).digest == first.digest)
        try library.appendParagraph("Новая строка", to: library.root)
        #expect(try build(includeSubpages: false).digest != first.digest)
    }

    @Test("Страница в корзине не публикуется")
    func trashedRootIsNotBuilt() throws {
        let builder = SharedDocumentBuilder(store: library.store, collapsedBlockIds: { _ in [] })
        #expect(try builder.build(rootPageId: library.trashed, includeSubpages: true) == nil)
    }
}
