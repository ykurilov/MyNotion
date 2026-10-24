import Backlinks
import ControlProtocol
import Databases
import Foundation
import PageSearch
import Sync
import Testing
@testable import ControlCommands
@testable import NotesCore

/// Команды `page …` и `trash …` (этап 2, US1): через операции дерева сессии и открытые документы.
@MainActor @Suite struct PageCommandsTests {
    let host: TestHost
    let executor: CommandExecutor

    init() throws {
        host = try TestHost()
        host.store.addWriteHook(SearchIndexer())
        host.store.addWriteHook(PageLinkIndexer())
        executor = CommandExecutor(host: host, registry: HandlerRegistry(PageHandlers.all), log: RecordingLog())
    }

    func run(_ command: String, _ args: [String: ControlJSON] = [:], cwd: String? = nil) async -> ControlResponse {
        await executor.run(ControlRequest(command: command, args: args, agent: "codex", cwd: cwd))
    }

    @discardableResult
    func ok(_ command: String, _ args: [String: ControlJSON] = [:], cwd: String? = nil) async throws -> ControlJSON {
        let response = await run(command, args, cwd: cwd)
        try #require(response.ok, "\(command): \(response.error?.message ?? "")")
        return try #require(response.data)
    }

    func id(_ json: ControlJSON?) throws -> UUID {
        try #require(json?["id"]?.string.flatMap(UUID.init(uuidString:)))
    }

    func titles(_ items: ControlJSON?) -> [String] {
        items?.array?.compactMap { $0["title"]?.string } ?? []
    }

    // MARK: Дерево и чтение

    @Test func treeHasDepthBranchNoTrashNoRowTemplates() async throws {
        let projects = try host.page("Проекты")
        let meeting = try host.page("Встреча", parent: projects.id)
        try host.page("Итоги", parent: meeting.id)
        let draft = try host.page("Черновик")
        try host.store.write { tx in
            var page = try #require(try tx.page(draft.id))
            page.trashedAt = Date()
            _ = try tx.updatePage(page)
        }
        let databases = DatabaseOperations(store: host.store, undoManager: UndoManager())
        let database = try databases.createDatabase(in: nil, isInline: false, title: "Задачи")
        try databases.addRow(to: database.databaseId, in: nil, title: "Строка")
        let templateId = try databases.addRow(to: database.databaseId, in: nil, title: "Шаблон строки")
        try host.store.write { tx in
            var template = try #require(try tx.page(templateId))
            template.isTemplate = true
            _ = try tx.updatePage(template)
        }

        let tree = try await ok("page.tree", ["depth": 1])
        #expect(titles(tree["items"]) == ["Проекты", "Задачи"])
        #expect(tree["items"]?[0]?["children"]?.array?.isEmpty == false)
        #expect(tree["items"]?[0]?["children"]?[0]?["children"] == nil)
        #expect(tree["items"]?[0]?["hasChildren"] == true)
        #expect(tree["items"]?[1]?["kind"] == "database")
        #expect(titles(tree["items"]?[1]?["children"]) == ["Строка"])
        #expect(tree["items"]?[1]?["children"]?[0]?["kind"] == "row")

        let branch = try await ok("page.tree", ["page": "Проекты"])
        #expect(titles(branch["items"]) == ["Встреча"])
        #expect(titles(branch["items"]?[0]?["children"]) == ["Итоги"])
        #expect(branch["items"]?[0]?["path"] == ["Проекты", "Встреча"])

        let first = try await ok("page.tree", ["depth": 0, "limit": 1])
        #expect(titles(first["items"]) == ["Проекты"])
        let cursor = try #require(first["nextCursor"]?.string)
        let second = try await ok("page.tree", ["depth": 0, "limit": 1, "cursor": .string(cursor)])
        #expect(titles(second["items"]) == ["Задачи"])
        #expect(second["nextCursor"] == .null)
    }

    @Test func getAndRead() async throws {
        let projects = try host.page("Проекты")
        let page = try host.page("Встреча", parent: projects.id, texts: ["Первый", "Второй"])
        let got = try await ok("page.get", ["page": "Проекты/Встреча"])
        #expect(try id(got["page"]) == page.id)
        #expect(got["page"]?["path"] == ["Проекты", "Встреча"])
        #expect(got["page"]?["kind"] == "page")

        let markdown = try await ok("page.read", ["page": .string(page.id.controlText)])
        #expect(markdown["markdown"]?.string == "Первый\n\nВторой\n")
        #expect(try id(markdown["page"]) == page.id)

        let json = try await ok("page.read", ["page": .string(page.id.controlText), "format": "json"])
        #expect(json["blocks"]?.array?.compactMap { $0["text"]?.string } == ["Первый", "Второй"])
        #expect(json["blocks"]?[0]?["id"]?.string != nil)

        try host.page("Итоги", parent: page.id, texts: ["Вывод"])
        let withChildren = try await ok("page.read", ["page": .string(page.id.controlText), "withChildren": true])
        #expect(withChildren["children"]?[0]?["markdown"] == "Вывод\n")
        #expect(withChildren["children"]?[0]?["page"]?["title"] == "Итоги")
    }

    // MARK: Создание

    @Test func createAtRootUnderParentAfterWithIcon() async throws {
        let first = try await ok("page.create", ["title": "Первая"])
        #expect(first["page"]?["parentId"] == .null)
        #expect(first["page"]?["title"] == "Первая")
        let projects = try host.page("Проекты")
        let a = try await ok("page.create", ["parent": "Проекты", "title": "А", "icon": "🚀"])
        #expect(try id(a["page"]).uuidString.isEmpty == false)
        #expect(a["page"]?["parentId"] == .string(projects.id.controlText))
        #expect(a["page"]?["icon"] == "🚀")
        try await ok("page.create", ["parent": "Проекты", "title": "В"])
        try await ok("page.create", ["parent": "Проекты", "title": "Б", "after": "Проекты/А"])
        let tree = try await ok("page.tree", ["page": "Проекты"])
        #expect(titles(tree["items"]) == ["А", "Б", "В"])
        // Подстраница — пара: ссылка в родителе.
        let links = try host.store.pageContent(projects.id)?.blocks.filter { $0.kind == .pageLink }.count
        #expect(links == 3)
        let root = try await ok("page.create", ["title": "Вторая", "after": "Первая"])
        #expect(root["page"]?["parentId"] == .null)
        let roots = try await ok("page.tree", ["depth": 0])
        #expect(titles(roots["items"]).prefix(2) == ["Первая", "Вторая"])
    }

    @Test func createWithMarkdownAndTemplate() async throws {
        let created = try await ok("page.create", ["title": "Встреча", "markdown": "# План\n\n- [ ] позвонить"])
        let pageId = try id(created["page"])
        #expect(try host.store.pageContent(pageId)?.blocks.map(\.kind) == [.heading1, .checkbox])
        #expect(try host.stored(pageId)?.title == "Встреча")

        let template = try host.page("Шаблон", texts: ["Из шаблона"])
        try host.store.write { tx in
            var page = try #require(try tx.page(template.id))
            page.isTemplate = true
            _ = try tx.updatePage(page)
        }
        let fromTemplate = try await ok("page.create", ["title": "Отчёт", "template": "Шаблон"])
        let reportId = try id(fromTemplate["page"])
        #expect(try host.texts(reportId) == ["Из шаблона"])
        #expect(fromTemplate["page"]?["title"] == "Отчёт")
        #expect(fromTemplate["page"]?["isTemplate"] == false)

        let notTemplate = await run("page.create", ["title": "X", "template": "Встреча"])
        #expect(notTemplate.error?.code == .templateNotFound)
    }

    // MARK: Содержимое

    @Test func writeReplacesAndRecordsAgentVersion() async throws {
        let page = try host.page("Заметка", texts: ["было"])
        let written = try await ok("page.write", ["page": "Заметка", "markdown": "## Стало\n\nтекст"])
        #expect(try id(written["page"]) == page.id)
        #expect(try host.texts(page.id) == ["Стало", "текст"])
        let versions = try host.versions.versions(ofPage: page.id).filter { $0.summary.agent == "codex" }
        #expect(versions.count == 1)
        #expect(versions.first?.summary.lines.first == "до правки агента (codex)")
        // Подстраница без ссылки в новом Markdown не теряет ссылку.
        let child = try await ok("page.create", ["parent": "Заметка", "title": "Подстраница"])
        try await ok("page.write", ["page": "Заметка", "markdown": "только текст"])
        let blocks = try #require(try host.store.pageContent(page.id)?.blocks)
        #expect(blocks.map(\.kind) == [.paragraph, .pageLink])
        #expect(blocks.last?.linkedPageId == (try id(child["page"])))
        // Пустой Markdown — пустая страница.
        try await ok("page.write", ["page": "Подстраница", "markdown": ""])
        #expect(try host.texts(try id(child["page"])) == [""])
    }

    @Test func appendAtEndAndAfterBlock() async throws {
        let page = try host.page("Список", texts: ["один", "три"])
        try await ok("page.append", ["page": "Список", "markdown": "четыре"])
        #expect(try host.texts(page.id) == ["один", "три", "четыре"])
        let first = try #require(try host.store.pageContent(page.id)?.blocks.first)
        let appended = try await ok("page.append", ["page": "Список", "markdown": "два\n\nдва с половиной",
                                                    "after": .string(first.id.controlText)])
        #expect(try host.texts(page.id) == ["один", "два", "два с половиной", "три", "четыре"])
        #expect(try id(appended["page"]) == page.id)
        let other = try host.page("Другая", texts: ["x"])
        let foreign = try #require(try host.store.pageContent(other.id)?.blocks.first)
        let wrong = await run("page.append", ["page": "Список", "markdown": "y", "after": .string(foreign.id.controlText)])
        #expect(wrong.error?.code == .wrongPage)
        #expect(try host.texts(page.id).count == 5)
    }

    @Test func unsupportedMarkdownWarnsWithLine() async throws {
        try host.page("Заметка")
        let response = await run("page.write", ["page": "Заметка", "markdown": "текст\n\n<div>html</div>"])
        #expect(response.ok)
        #expect(response.warnings.map(\.code) == [.markdownUnsupported])
        #expect(response.warnings.first?.line == 3)
    }

    @Test func localImageFromAgentFolder() async throws {
        try host.page("Заметка")
        let image = host.folder.url.appendingPathComponent("схема.png")
        try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==")!.write(to: image)
        try await ok("page.write", ["page": "Заметка", "markdown": "![Схема](схема.png)"], cwd: host.folder.url.path)
        let page = try #require(try host.store.pageOutline().first { $0.title == "Заметка" })
        let block = try #require(try host.store.pageContent(page.id)?.blocks.first)
        #expect(block.kind == .image)
        #expect(block.props.attachment?.name == "схема.png")
        let read = try await ok("page.read", ["page": "Заметка"])
        #expect(read["markdown"]?.string?.contains(host.attachments.folder.lastPathComponent) == true)
    }

    // MARK: Дерево правками

    @Test func renameMoveDuplicate() async throws {
        let projects = try host.page("Проекты")
        let meeting = try host.page("Встреча", parent: projects.id)
        let child = try host.page("Итоги", parent: meeting.id)
        let renamed = try await ok("page.rename", ["page": "Встреча", "title": "Встреча 24.10"])
        #expect(renamed["page"]?["title"] == "Встреча 24.10")

        let intoOwnBranch = await run("page.move", ["page": "Встреча 24.10", "parent": .string(child.id.controlText)])
        #expect(intoOwnBranch.error?.code == .cannotMove)
        let intoSelf = await run("page.move", ["page": "Встреча 24.10", "parent": .string(meeting.id.controlText)])
        #expect(intoSelf.error?.code == .cannotMove)

        let archive = try host.page("Архив")
        try host.page("Старое", parent: archive.id)
        let moved = try await ok("page.move", ["page": "Встреча 24.10", "parent": "Архив", "first": true])
        #expect(moved["page"]?["parentId"] == .string(archive.id.controlText))
        let firstOrder = try await ok("page.tree", ["page": "Архив", "depth": 0])
        #expect(titles(firstOrder["items"]) == ["Встреча 24.10", "Старое"])
        try await ok("page.move", ["page": "Встреча 24.10", "parent": "Архив", "after": "Архив/Старое"])
        let afterOrder = try await ok("page.tree", ["page": "Архив", "depth": 0])
        #expect(titles(afterOrder["items"]) == ["Старое", "Встреча 24.10"])
        let rooted = try await ok("page.move", ["page": "Встреча 24.10", "root": true])
        #expect(rooted["page"]?["parentId"] == .null)

        let copy = try await ok("page.duplicate", ["page": "Встреча 24.10"])
        #expect(try id(copy["page"]) != meeting.id)
        #expect(copy["page"]?["hasChildren"] == true)
    }

    @Test func trashRestoreListDeleteEmpty() async throws {
        let page = try host.page("Черновик", texts: ["текст"])
        let trashed = try await ok("page.trash", ["page": "Черновик"])
        #expect(trashed == ["id": .string(page.id.controlText), "inTrash": true])
        let list = try await ok("trash.list")
        #expect(titles(list["items"]) == ["Черновик"])
        let hidden = await run("page.get", ["page": "Черновик"])
        #expect(hidden.error?.code == .pageInTrash || hidden.error?.code == .pageNotFound)

        let restored = try await ok("page.restore", ["page": .string(page.id.controlText)])
        #expect(restored["page"]?["inTrash"] == false)
        try await ok("page.trash", ["page": "Черновик"])

        let withoutForce = await run("trash.delete", ["page": .string(page.id.controlText)])
        #expect(withoutForce.error?.code == .forceRequired)
        #expect(try host.stored(page.id) != nil)
        let deleted = try await ok("trash.delete", ["page": .string(page.id.controlText), "force": true])
        #expect(deleted["id"] == .string(page.id.controlText))
        #expect(try host.stored(page.id) == nil)

        try host.page("Ещё")
        try await ok("page.trash", ["page": "Ещё"])
        let refused = await run("trash.empty")
        #expect(refused.error?.code == .forceRequired)
        let kept = try await ok("trash.list")
        #expect(titles(kept["items"]) == ["Ещё"])
        let emptied = try await ok("trash.empty", ["force": true])
        #expect(emptied["deleted"]?.array?.count == 1)
        let left = try await ok("trash.list")
        #expect(titles(left["items"]).isEmpty)
    }

    @Test func layout() async throws {
        try host.page("Широкая")
        let wide = try await ok("page.layout", ["page": "Широкая", "fullWidth": "on"])
        #expect(wide["page"]?["fullWidth"] == true)
        #expect(wide["page"]?["smallText"] == false)
        let small = try await ok("page.layout", ["page": "Широкая", "fullWidth": "off", "smallText": "on"])
        #expect(small["page"]?["fullWidth"] == false)
        #expect(small["page"]?["smallText"] == true)
    }

    @Test func everyEditReturnsWholePage() async throws {
        try host.page("Цель", texts: ["x"])
        let commands: [(String, [String: ControlJSON])] = [
            ("page.create", ["title": "Новая"]), ("page.write", ["page": "Цель", "markdown": "y"]),
            ("page.append", ["page": "Цель", "markdown": "z"]), ("page.rename", ["page": "Цель", "title": "Цель 2"]),
            ("page.move", ["page": "Новая", "parent": "Цель 2"]), ("page.layout", ["page": "Цель 2", "smallText": "on"]),
            ("page.duplicate", ["page": "Цель 2"]),
        ]
        for (command, args) in commands {
            let page = try await ok(command, args)["page"]
            for key in ["id", "title", "icon", "kind", "parentId", "path", "hasChildren", "cover", "fullWidth", "smallText",
                        "isFavorite", "isTemplate", "inTrash", "createdAt", "updatedAt"] {
                #expect(page?[key] != nil, "\(command): нет \(key)")
            }
        }
    }

    // MARK: Синхронизация, поиск, обратные ссылки

    @Test func writesReachOutboxSearchAndBacklinks() async throws {
        Outbox.install(on: host.store)
        try SyncSetup.enable(store: host.store, account: SyncAccount(serverURL: URL(string: "https://example.com")!, deviceId: "mac-a",
                                                                    deviceName: "Mac A"))
        // Индекс ссылок приложение строит при запуске; дальше его держит подписчик записи.
        _ = try await BacklinkIndexBuild(store: host.store).runIfNeeded()
        let target = try host.page("План проекта")
        let before = try Outbox(store: host.store).pendingEntries().count
        let created = try await ok("page.create", ["title": "Встреча", "markdown": "Обсудили слово кашалот"])
        let pageId = try id(created["page"])
        try await ok("page.write", ["page": .string(pageId.controlText),
                                    "markdown": .string("Обсудили слово кашалот\n\n[План проекта](mynotion://page/\(target.id.controlText))")])
        #expect(try Outbox(store: host.store).pendingEntries().count > before)
        let results = try PageSearch(store: host.store).results(for: "кашалот", in: try host.store.pageTree())
        #expect(results.map(\.pageId) == [pageId])
        #expect(try Backlinks(store: host.store).sources(of: target.id).map(\.pageId) == [pageId])
    }

    // MARK: Откат

    @Test func failedWriteRollsBackAndWriteUndoes() async throws {
        let page = try host.page("Заметка", texts: ["было"])
        let missing = await run("page.append", ["page": "Заметка", "markdown": "x", "after": .string(UUID().uuidString)])
        #expect(missing.error?.code == .blockNotFound)
        #expect(try host.texts(page.id) == ["было"])
        try await ok("page.write", ["page": "Заметка", "markdown": "стало"])
        let undo = try #require(executor.lastUndoManager)
        undo.undo()
        #expect(try host.texts(page.id) == ["было"])
    }
}
