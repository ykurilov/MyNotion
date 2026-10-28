import ControlProtocol
import Foundation
import Testing
@testable import ControlCommands
@testable import NotesCore

@MainActor @Suite struct LocatorTests {
    let host: TestHost
    let projects: Page
    let meeting: Page
    let archiveMeeting: Page

    init() throws {
        host = try TestHost()
        projects = try host.page("Проекты")
        meeting = try host.page("Встреча", parent: projects.id)
        let archive = try host.page("Архив")
        archiveMeeting = try host.page("Встреча", parent: archive.id)
    }

    var locator: PageLocator { PageLocator(store: host.store, currentPageId: { [host] in host.window.currentPageId }) }

    func failure(_ text: String, includeTrashed: Bool = false) -> ControlError? {
        do {
            _ = try locator.resolve(text, includeTrashed: includeTrashed)
            return nil
        } catch {
            return error
        }
    }

    @Test func byIdAnyCase() throws {
        #expect(try locator.resolve(meeting.id.uuidString.uppercased()).id == meeting.id)
        #expect(try locator.resolve(meeting.id.uuidString.lowercased()).id == meeting.id)
    }

    /// Ссылка, скопированная в приложении («Копировать ссылку», ⌘L) или из поля `link`, — тоже указатель.
    @Test func byPageLink() throws {
        #expect(try locator.resolve(PageAddress(pageId: meeting.id).text).id == meeting.id)
        #expect(try locator.resolve(" " + PageAddress(pageId: meeting.id, blockId: UUID()).text + "\n").id == meeting.id)
        #expect(failure(PageAddress(pageId: UUID()).text)?.code == .pageNotFound)
    }

    @Test func byIdPrefix() throws {
        // id v7 начинаются со времени: страницы одной миллисекунды делят первые знаки — берём кратчайшее отличающее начало.
        let ids = try host.store.pageOutline().map { $0.id.uuidString.lowercased() }
        let id = meeting.id.uuidString.lowercased()
        let prefix = try #require((8...36).lazy.map { String(id.prefix($0)) }
            .first { start in ids.filter { $0.hasPrefix(start) }.count == 1 })
        #expect(try locator.resolve(prefix).id == meeting.id)
        // Короче 8 знаков — не id, а название: такой страницы нет.
        #expect(failure(String(prefix.prefix(6)))?.code == .pageNotFound)
    }

    @Test func current() throws {
        #expect(failure("current")?.code == .pageNotFound)
        host.window.currentPageId = meeting.id
        #expect(try locator.resolve("current").id == meeting.id)
    }

    @Test func pathFromRoot() throws {
        #expect(try locator.resolve("Проекты/Встреча").id == meeting.id)
        #expect(try locator.resolve("проекты/встреча").id == meeting.id)
        #expect(try locator.resolve("/Проекты/Встреча/").id == meeting.id)
    }

    @Test func yoAndYeMatch() throws {
        let tree = try host.page("Ёлка")
        #expect(try locator.resolve("елка").id == tree.id)
    }

    @Test func slashInsideTitle() throws {
        let page = try host.page("Q1/Q2", parent: projects.id)
        #expect(try locator.resolve(#"Проекты/Q1\/Q2"#).id == page.id)
    }

    @Test func ambiguousTitleListsCandidates() {
        let error = failure("Встреча")
        #expect(error?.code == .ambiguousPage)
        let candidates = error?.details?["candidates"]?.array ?? []
        #expect(Set(candidates.compactMap { $0["id"]?.string }) == [meeting.id.uuidString.lowercased(), archiveMeeting.id.uuidString.lowercased()])
        #expect(candidates.contains { $0["path"] == "Проекты/Встреча" })
    }

    @Test func uniqueTitleAnywhere() throws {
        let deep = try host.page("Протокол", parent: meeting.id)
        #expect(try locator.resolve("Протокол").id == deep.id)
        #expect(try locator.resolve("Встреча/Протокол").id == deep.id)
    }

    /// Путь, как его показывает полоса над страницей: иконка перед названием. С иконкой и без — та же страница.
    @Test func segmentWithIcon() throws {
        let launches = try host.page("Запуски")
        let seller = try host.page("Нейропродавец", parent: launches.id)
        try host.store.write { tx in
            for (id, icon) in [(launches.id, "🚀"), (seller.id, "🤖")] {
                var page = try #require(try tx.page(id))
                page.icon = icon
                try tx.updatePage(page)
            }
        }
        #expect(try locator.resolve("🚀 Запуски/Нейропродавец").id == seller.id)
        #expect(try locator.resolve("Запуски/🤖 Нейропродавец").id == seller.id)
        #expect(try locator.resolve("/🚀 Запуски/🤖 Нейропродавец").id == seller.id)
        #expect(try locator.resolve("🤖 Нейропродавец").id == seller.id)
        #expect(failure("🎯 Запуски/Нейропродавец")?.code == .pageNotFound)
    }

    @Test func missingPage() {
        let error = failure("Проекты/Встрча")
        #expect(error?.code == .pageNotFound)
        #expect(error?.hint?.contains("page tree") == true)
    }

    @Test func trashedPageNeedsFlag() throws {
        try host.store.write { tx in
            var page = try tx.page(projects.id)!
            page.trashedAt = Date()
            try tx.updatePage(page)
        }
        #expect(failure("Проекты/Встреча")?.code == .pageInTrash)
        #expect(failure(meeting.id.uuidString)?.code == .pageInTrash)
        #expect(try locator.resolve("Проекты/Встреча", includeTrashed: true).id == meeting.id)
        // Вне корзины имя теперь однозначно.
        #expect(try locator.resolve("Встреча").id == archiveMeeting.id)
    }

    @Test func blockOfOtherPageIsWrongPage() throws {
        let other = try host.page("Другая", texts: ["чужой"])
        let mine = try host.page("Моя", texts: ["свой"])
        let foreign = try #require(try host.store.pageContent(other.id)?.blocks.first)
        let own = try #require(try host.store.pageContent(mine.id)?.blocks.first)
        let blocks = BlockLocator(store: host.store)
        #expect(try blocks.resolve(own.id.uuidString, inPage: mine.id).id == own.id)
        #expect(try blocks.resolve(foreign.id.uuidString).id == foreign.id)
        #expect(throws: ControlError.self) { try blocks.resolve(foreign.id.uuidString, inPage: mine.id) }
        do {
            _ = try blocks.resolve(foreign.id.uuidString, inPage: mine.id)
        } catch {
            #expect(error.code == .wrongPage)
            #expect(error.details?["pageId"] == .string(other.id.uuidString.lowercased()))
        }
        do {
            _ = try blocks.resolve(UUID().uuidString)
        } catch {
            #expect(error.code == .blockNotFound)
        }
    }
}
