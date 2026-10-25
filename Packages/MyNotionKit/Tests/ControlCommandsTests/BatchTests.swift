import ControlProtocol
import Databases
import Foundation
import Testing
@testable import ControlCommands
@testable import NotesCore

/// Пакет на настоящих операциях: подставные обработчики пишут через `pageTree` и `databases` сессии.
@MainActor @Suite struct BatchTests {
    let host: TestHost
    let root: Page
    let database: CreatedDatabase
    let rowId: UUID

    init() throws {
        host = try TestHost()
        root = try host.page("Корень", texts: ["абзац"])
        let operations = DatabaseOperations(store: host.store)
        database = try operations.createDatabase(in: root.id, isInline: false, title: "Задачи")
        rowId = try operations.addRow(to: database.databaseId, in: database.viewId, title: "Отчёт")
    }

    static let handlers: [String: CommandHandler] = [
        "page.create": { session in
            let parent = try session.page("parent")
            let page = try session.pageTree.createSubpage(in: parent.id, title: session.string("title") ?? "")
            return CommandResult(["page": ["id": .string(page.id.uuidString.lowercased()), "title": .string(page.title)]])
        },
        "page.rename": { session in
            let page = try session.page()
            try await session.willWrite(page.id)
            try session.pageTree.rename(page.id, to: session.string("title") ?? "")
            return CommandResult(["page": ["id": .string(page.id.uuidString.lowercased())]])
        },
        "db.cell.set": { session in
            let row = try #require(UUID(uuidString: session.string("row") ?? ""))
            let property = try #require(UUID(uuidString: session.string("property") ?? ""))
            try session.databases.setTitle(of: row, to: session.args["value"]?.string ?? "")
            _ = property
            return CommandResult()
        },
    ]

    var executor: CommandExecutor {
        CommandExecutor(host: host, registry: HandlerRegistry(Self.handlers.merging(ServiceHandlers.all) { first, _ in first }),
                        log: RecordingLog())
    }

    func batch(_ steps: ControlJSON) async -> ControlResponse {
        await executor.run(ControlRequest(command: "batch", args: ["steps": steps]))
    }

    func snapshot() throws -> (pages: [String], blocks: [String], rowTitle: String?) {
        let outline = try host.store.treeOutline()
        return (outline.pages.map(\.title).sorted(), try host.texts(root.id) + (try host.store.pageContent(root.id)?.blocks.map(\.kind.rawValue) ?? []),
                try host.stored(rowId)?.title)
    }

    @Test func failedStepRollsBackEverything() async throws {
        let before = try snapshot()
        let response = await batch([
            ["command": "page.create", "args": ["parent": "Корень", "title": "Новая"]],
            ["command": "db.cell.set", "args": ["database": "Задачи", "row": .string(rowId.uuidString), "property": .string(database.titlePropertyId.uuidString),
                                               "value": "Переименованный отчёт"]],
            ["command": "page.rename", "args": ["page": "Нет такой страницы", "title": "Б"]],
        ])
        #expect(response.error?.code == .batchFailed)
        #expect(response.error?.details?["step"] == 3)
        #expect(response.error?.details?["error"]?["code"] == "page_not_found")
        let after = try snapshot()
        #expect(after.pages == before.pages)
        #expect(after.blocks == before.blocks)
        #expect(after.rowTitle == before.rowTitle)
    }

    @Test func stepResultsCanBeReferenced() async throws {
        let response = await batch([
            ["command": "page.create", "args": ["parent": "Корень", "title": "А"]],
            ["command": "page.rename", "args": ["page": "$1.page.id", "title": "Б"]],
        ])
        #expect(response.ok, "\(String(describing: response.error))")
        #expect(response.data?["steps"]?.array?.count == 2)
        let created = try #require(response.data?["steps"]?[0]?["page"]?["id"]?.string.flatMap(UUID.init(uuidString:)))
        #expect(try host.stored(created)?.title == "Б")
    }

    @Test func stepsAcceptSpacedCommandNames() async {
        let response = await batch([["command": "page create", "args": ["parent": "Корень", "title": "А"]]])
        #expect(response.ok)
    }

    @Test func notBatchableCommandRefusedBeforeRunning() async throws {
        let before = try snapshot()
        let response = await batch([
            ["command": "page.create", "args": ["parent": "Корень", "title": "Новая"]],
            ["command": "trash.empty", "args": ["force": true]],
        ])
        #expect(response.error?.code == .notBatchable)
        #expect(response.error?.details?["step"] == 2)
        #expect(try snapshot().pages == before.pages)
    }

    @Test func invalidStepArgumentsRefusedBeforeRunning() async throws {
        let before = try snapshot()
        let response = await batch([
            ["command": "page.create", "args": ["parent": "Корень", "title": "Новая"]],
            ["command": "page.rename", "args": ["page": "Корень"]],
        ])
        #expect(response.error?.code == .missingArgument)
        #expect(response.error?.details?["step"] == 2)
        #expect(try snapshot().pages == before.pages)
    }

    @Test func badReferenceFailsTheBatch() async throws {
        let response = await batch([
            ["command": "page.create", "args": ["parent": "Корень", "title": "А"]],
            ["command": "page.rename", "args": ["page": "$1.nothing.here", "title": "Б"]],
        ])
        #expect(response.error?.code == .batchFailed)
        #expect(response.error?.details?["error"]?["code"] == "invalid_argument")
    }

    @Test func stepsMustBeAList() async {
        #expect(await batch(["command": "page.create"]).error?.code == .invalidValue)
        #expect(await batch([]).error?.code == .invalidValue)
    }

    @Test func agentCheckpointInsideBatch() async throws {
        let response = await executor.run(ControlRequest(command: "batch", args: ["steps": [
            ["command": "page.rename", "args": ["page": "Корень", "title": "Б"]],
            ["command": "page.rename", "args": ["page": "Б", "title": "В"]],
        ]], agent: "codex"))
        #expect(response.ok)
        let versions = try host.versions.versions(ofPage: root.id)
        #expect(versions.filter { $0.summary.agent == "codex" }.count == 1)
    }
}
