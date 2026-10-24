import ControlProtocol
import Foundation
import Testing
@testable import ControlCommands
@testable import NotesCore
@testable import PageVersions

/// История версий (этап 5, US4): список с именем агента, просмотр версии, восстановление как в окне истории.
@MainActor @Suite struct HistoryCommandsTests {
    let host: TestHost
    let executor: CommandExecutor

    init() throws {
        host = try TestHost()
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

    /// Страница «Отчёт», которую агент переписал: в истории есть «до правки агента».
    func editedByAgent() async throws -> Page {
        let page = try host.page("Отчёт", texts: ["было", "второй абзац"])
        host.clock.advance(minutes: 1)
        try await ok("page.write", ["page": "Отчёт", "markdown": "испорчено агентом"])
        return page
    }

    func agentVersionId(_ list: ControlJSON) throws -> String {
        try #require(list["items"]?.array?.first { $0["agent"] == "codex" }?["id"]?.string)
    }

    @Test func listShowsAgentVersion() async throws {
        let page = try await editedByAgent()
        let list = try await ok("history.list", ["page": "Отчёт"])
        let items = try #require(list["items"]?.array)
        #expect(items.count == (try host.versions.versions(ofPage: page.id)).count)
        let agent = try #require(items.first { $0["agent"] == "codex" })
        #expect(agent["summary"]?.string?.contains("до правки агента (codex)") == true)
        #expect(agent["createdAt"]?.string != nil)
        #expect(agent["device"]?.string != nil)
        // Первой строкой — текущий вид, как в окне истории.
        let latest = try #require(try host.versions.latest(ofPage: page.id))
        #expect(items.first?["id"]?.string == latest.info.id.controlText)
        #expect(latest.snapshot.blocks.map(\.text.string) == ["испорчено агентом"])
    }

    @Test func listWaitsForRunningWrite() async throws {
        try host.page("Отчёт", texts: ["было"])
        let events = EventLog()
        let slowRename: CommandHandler = { _ in
            events.events.append("write start")
            try await Task.sleep(for: .milliseconds(300))
            events.events.append("write end")
            return CommandResult()
        }
        let executor = CommandExecutor(host: host, registry: HandlerRegistry(HandlerRegistry.standard.handlers.merging(["page.rename": slowRename]) { _, new in new }),
                                       log: RecordingLog())
        async let write = executor.run(ControlRequest(command: "page.rename", args: ["page": "Отчёт", "title": "Б"]))
        try await Task.sleep(for: .milliseconds(30))
        // Список сохраняет открытую правку версией — это запись: посреди чужой записи ей не место.
        let list = await executor.run(ControlRequest(command: "history.list", args: ["page": "Отчёт"]))
        events.events.append("list")
        #expect(list.ok)
        _ = await write
        #expect(events.events == ["write start", "write end", "list"])
    }

    @Test func showVersionAsMarkdownAndJSON() async throws {
        try await editedByAgent()
        let versionId = try agentVersionId(try await ok("history.list", ["page": "Отчёт"]))
        let markdown = try await ok("history.show", ["page": "Отчёт", "version": .string(versionId)])
        #expect(markdown["markdown"] == "было\n\nвторой абзац\n")
        #expect(markdown["version"]?["id"]?.string == versionId)
        #expect(markdown["title"] == "Отчёт")
        let json = try await ok("history.show", ["page": "Отчёт", "version": .string(versionId), "format": "json"])
        #expect(json["blocks"]?.array?.compactMap { $0["text"]?.string } == ["было", "второй абзац"])

        let missing = await run("history.show", ["page": "Отчёт", "version": .string(UUID().uuidString)])
        #expect(missing.error?.code == .versionNotFound)
    }

    @Test func restoreReturnsVersionAndKeepsBefore() async throws {
        let page = try await editedByAgent()
        let versionId = try agentVersionId(try await ok("history.list", ["page": "Отчёт"]))
        let countBefore = try host.versions.versions(ofPage: page.id).count
        let restored = try await ok("history.restore", ["page": "Отчёт", "version": .string(versionId)])
        #expect(restored["page"]?["id"]?.string == page.id.controlText)
        #expect(try host.texts(page.id) == ["было", "второй абзац"])
        // Вид «до восстановления» помечен, после восстановления — новая версия.
        let stamps = try #require(try host.versions.allVersionStamps()[page.id])
        #expect(stamps.contains { $0.isBeforeRestore })
        #expect(try host.versions.versions(ofPage: page.id).count > countBefore)
        #expect(host.treeChanges.contains { $0.contains(page.id) })
    }

    @Test func restoreIsNotBatchable() async throws {
        try await editedByAgent()
        let versionId = try agentVersionId(try await ok("history.list", ["page": "Отчёт"]))
        let response = await run("batch", ["steps": [["command": "history.restore", "args": ["page": "Отчёт", "version": .string(versionId)]]]])
        #expect(response.error?.code == .notBatchable)
        #expect(try host.texts(try #require(try host.store.pageTree().children(of: nil).first).id) == ["испорчено агентом"])
    }
}
