import ControlProtocol
import Foundation
import PageSearch
import Testing
@testable import ControlCommands
@testable import NotesCore

/// Поиск, избранное, недавние, шаблоны (этап 5, US4): та же выдача и те же операции, что в окне.
@MainActor @Suite struct LibraryCommandsTests {
    let host: TestHost
    let executor: CommandExecutor

    init() throws {
        host = try TestHost()
        host.store.addWriteHook(SearchIndexer())
        executor = CommandExecutor(host: host, log: RecordingLog())
    }

    func run(_ command: String, _ args: [String: ControlJSON] = [:]) async -> ControlResponse {
        await executor.run(ControlRequest(command: command, args: args, agent: "codex"))
    }

    @discardableResult
    func ok(_ command: String, _ args: [String: ControlJSON] = [:], sourceLocation: SourceLocation = #_sourceLocation) async throws -> ControlJSON {
        let response = await run(command, args)
        try #require(response.ok, "\(command): \(response.error?.code.rawValue ?? "") \(response.error?.message ?? "")", sourceLocation: sourceLocation)
        return try #require(response.data, sourceLocation: sourceLocation)
    }

    func titles(_ data: ControlJSON) -> [String] {
        data["items"]?.array?.compactMap { $0["title"]?.string } ?? []
    }

    func ids(_ data: ControlJSON) -> [String] {
        data["items"]?.array?.compactMap { $0["id"]?.string } ?? []
    }

    // MARK: Поиск

    @Test func searchMatchesWindowSearch() async throws {
        let projects = try host.page("Проекты")
        let report = try host.page("Отчёт за октябрь", parent: projects.id, texts: ["вводная"])
        let notes = try host.page("Заметки", texts: ["здесь черновик отчёта по продажам", "другое"])
        let trashed = try host.page("Отчёт в корзине")
        try host.store.write { tx in
            var page = try #require(try tx.page(trashed.id))
            page.trashedAt = Date()
            _ = try tx.updatePage(page)
        }

        let data = try await ok("search", ["query": "отчёт"])
        let expected = try PageSearch(store: host.store).results(for: "отчёт", in: host.store.pageTree())
        #expect(ids(data) == expected.map { $0.pageId.controlText })
        #expect(Set(ids(data)) == [report.id.controlText, notes.id.controlText])
        let first = try #require(data["items"]?[0])
        #expect(first["title"] == "Отчёт за октябрь")
        #expect(first["path"] == ["Проекты", "Отчёт за октябрь"])
        #expect(first["kind"] == "page")
        let found = try #require(data["items"]?.array?.first { $0["id"]?.string == notes.id.controlText })
        #expect(found["snippet"]?.string?.contains("отчёта") == true)
        #expect(found["blockId"]?.string != nil)

        let limited = try await ok("search", ["query": "отчёт", "limit": 1])
        #expect(ids(limited) == [expected[0].pageId.controlText])
        let none = try await ok("search", ["query": "несуществующееслово"])
        #expect(none["items"] == [])
    }

    // MARK: Избранное и недавние

    @Test func favoritesAddMoveRemoveList() async throws {
        try host.page("А")
        try host.page("Б")
        try host.page("В")
        let added = try await ok("favorites.add", ["page": "А"])
        #expect(added["page"]?["isFavorite"] == true)
        try await ok("favorites.add", ["page": "Б"])
        try await ok("favorites.add", ["page": "В"])
        // Повторное добавление ничего не меняет.
        try await ok("favorites.add", ["page": "А"])
        #expect(titles(try await ok("favorites.list")) == ["А", "Б", "В"])
        #expect(try host.store.favoritePages().map(\.title) == ["А", "Б", "В"])

        try await ok("favorites.move", ["page": "В", "index": 0])
        #expect(titles(try await ok("favorites.list")) == ["В", "А", "Б"])

        let removed = try await ok("favorites.remove", ["page": "А"])
        #expect(removed["page"]?["isFavorite"] == false)
        #expect(titles(try await ok("favorites.list")) == ["В", "Б"])
        #expect(!host.treeChanges.isEmpty)

        let notFavorite = await run("favorites.move", ["page": "А", "index": 0])
        #expect(notFavorite.error?.code == .invalidValue)
    }

    @Test func recentsAsSidebar() async throws {
        let pages = try ["Первая", "Вторая", "Третья"].map { try host.page($0) }
        let template = try host.page("Шаблон")
        try host.store.write { tx in
            for (offset, page) in (pages + [template]).enumerated() {
                var stored = try #require(try tx.page(page.id))
                stored.visitedAt = Date(timeIntervalSince1970: 1_800_000_000 + Double(offset) * 60)
                stored.isTemplate = page.id == template.id
                _ = try tx.updatePage(stored)
            }
        }
        let data = try await ok("recents")
        #expect(try titles(data) == host.store.recentPages(limit: 50).map(\.title))
        #expect(titles(data) == ["Третья", "Вторая", "Первая"])
        #expect(data["items"]?[0]?["visitedAt"]?.string != nil)
        #expect(titles(try await ok("recents", ["limit": 2])) == ["Третья", "Вторая"])
    }

    // MARK: Шаблоны

    @Test func templateMarkListUnmarkAndCreate() async throws {
        let parent = try host.page("Встречи")
        try host.page("Шаблон встречи", parent: parent.id, texts: ["Повестка"])
        let marked = try await ok("template.mark", ["page": "Встречи/Шаблон встречи"])
        #expect(marked["page"]?["isTemplate"] == true)
        // Как «Сделать шаблоном» в окне: страница уходит в корень.
        #expect(marked["page"]?["parentId"] == .null)
        #expect(titles(try await ok("template.list")) == ["Шаблон встречи"])

        let created = try await ok("page.create", ["title": "Встреча 25.10", "template": "Шаблон встречи"])
        let createdId = try #require(created["page"]?["id"]?.string.flatMap(UUID.init(uuidString:)))
        #expect(try host.texts(createdId) == ["Повестка"])

        let unmarked = try await ok("template.unmark", ["page": "Шаблон встречи"])
        #expect(unmarked["page"]?["isTemplate"] == false)
        #expect(titles(try await ok("template.list")) == [])
    }
}
