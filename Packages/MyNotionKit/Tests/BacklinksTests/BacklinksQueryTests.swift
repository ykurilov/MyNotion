import Foundation
import Testing
@testable import Backlinks
@testable import NotesCore

/// Счёт и список обратных ссылок (research R10, tasks.md T068).
@Suite("Запросы обратных ссылок")
struct BacklinksQueryTests {
    @Test("Считаются разные страницы-источники, а не упоминания")
    func countsDistinctSourcePages() throws {
        let library = try BacklinksLibrary()
        let target = try library.page("Б")
        let first = try library.page("А")
        let second = try library.page("В")
        try library.addMention(of: target.id, on: first.id)
        try library.addMention(of: target.id, on: first.id)
        try library.addMention(of: target.id, on: second.id)
        #expect(try library.backlinks.count(of: target.id) == 2)
    }

    @Test("Упоминание, упоминание и ссылка-подстраница с трёх страниц — три")
    func mentionsAndPageLink() throws {
        let library = try BacklinksLibrary()
        let target = try library.page("Б")
        let a = try library.page("А")
        let b = try library.page("В")
        let g = try library.page("Г")
        try library.addMention(of: target.id, on: a.id)
        try library.addMention(of: target.id, on: b.id)
        try library.addPageLink(to: target.id, on: g.id)
        #expect(try library.backlinks.count(of: target.id) == 3)
    }

    @Test("Страница в корзине и страница под страницей в корзине не считаются; из корзины вернулась — считается")
    func trashedSourcesAreNotCounted() throws {
        let library = try BacklinksLibrary()
        let target = try library.page("Б")
        let top = try library.page("Верх")
        let nested = try library.page("Вложенная", parent: top.id)
        try library.addMention(of: target.id, on: top.id)
        try library.addMention(of: target.id, on: nested.id)
        #expect(try library.backlinks.count(of: target.id) == 2)
        try library.trash(top.id)
        #expect(try library.backlinks.count(of: target.id) == 0)
        try library.store.write { transaction in
            var page = try #require(try transaction.page(top.id))
            page.trashedAt = nil
            try transaction.updatePage(page)
        }
        #expect(try library.backlinks.count(of: target.id) == 2)
    }

    @Test("Шаблон и всё под шаблоном не считаются")
    func templatesAreNotCounted() throws {
        let library = try BacklinksLibrary()
        let target = try library.page("Б")
        let template = try library.page("Шаблон", isTemplate: true)
        let underTemplate = try library.page("Под шаблоном", parent: template.id)
        try library.addMention(of: target.id, on: template.id)
        try library.addMention(of: target.id, on: underTemplate.id)
        #expect(try library.backlinks.count(of: target.id) == 0)
    }

    @Test("Сама страница себя не считает")
    func selfIsNotCounted() throws {
        let library = try BacklinksLibrary()
        let target = try library.page("Б")
        try library.addMention(of: target.id, on: target.id)
        #expect(try library.backlinks.count(of: target.id) == 0)
    }

    @Test("Пока индекс не построен, счёт нулевой и список пуст")
    func notBuiltYet() throws {
        let library = try BacklinksLibrary(indexBuilt: false)
        let target = try library.page("Б")
        let source = try library.page("А")
        try library.addMention(of: target.id, on: source.id)
        #expect(try library.backlinks.count(of: target.id) == 0)
        #expect(try library.backlinks.sources(of: target.id).isEmpty)
    }

    @Test("Список: страница-источник и первый по порядку блок со ссылкой")
    func listPointsAtFirstLinkBlock() throws {
        let library = try BacklinksLibrary()
        let target = try library.page("Б")
        let source = try library.page("А")
        let first = try library.addMention(of: target.id, on: source.id)
        try library.addMention(of: target.id, on: source.id)
        let other = try library.page("В")
        let otherBlock = try library.addPageLink(to: target.id, on: other.id)
        let sources = try library.backlinks.sources(of: target.id)
        #expect(Set(sources.map(\.pageId)) == [source.id, other.id])
        #expect(sources.first { $0.pageId == source.id }?.blockId == first.id)
        #expect(sources.first { $0.pageId == other.id }?.blockId == otherBlock.id)
    }

    @Test("Склонение: 1 обратная ссылка, 3 обратные ссылки, 5 обратных ссылок")
    func declension() {
        #expect(Backlinks.phrase(count: 1) == "1 обратная ссылка")
        #expect(Backlinks.phrase(count: 2) == "2 обратные ссылки")
        #expect(Backlinks.phrase(count: 3) == "3 обратные ссылки")
        #expect(Backlinks.phrase(count: 4) == "4 обратные ссылки")
        #expect(Backlinks.phrase(count: 5) == "5 обратных ссылок")
        #expect(Backlinks.phrase(count: 11) == "11 обратных ссылок")
        #expect(Backlinks.phrase(count: 14) == "14 обратных ссылок")
        #expect(Backlinks.phrase(count: 21) == "21 обратная ссылка")
        #expect(Backlinks.phrase(count: 22) == "22 обратные ссылки")
        #expect(Backlinks.phrase(count: 30) == "30 обратных ссылок")
    }
}
