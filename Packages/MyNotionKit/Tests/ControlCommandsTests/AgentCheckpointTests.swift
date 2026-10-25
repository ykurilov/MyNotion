import ControlProtocol
import Foundation
import Testing
@testable import ControlCommands
@testable import NotesCore
@testable import PageVersions

@MainActor @Suite struct AgentCheckpointTests {
    let host: TestHost

    init() throws {
        host = try TestHost()
    }

    var checkpoint: AgentEditCheckpoint { AgentEditCheckpoint(host: host) }

    func agentVersions(_ pageId: UUID) throws -> [PageVersionInfo] {
        try host.versions.versions(ofPage: pageId).filter { $0.summary.agent != nil }
    }

    @Test func firstWriteRecordsAgentVersion() async throws {
        let page = try host.page("А", texts: ["было"])
        try await checkpoint.beforeWriting(page.id, agent: "codex")
        let versions = try agentVersions(page.id)
        #expect(versions.count == 1)
        #expect(versions.first?.summary.agent == "codex")
        #expect(versions.first?.summary.lines.first == "до правки агента (codex)")
        #expect(versions.first?.createdAt == host.clock.now)
    }

    @Test func freshCheckpointCoversTenMinutes() async throws {
        let page = try host.page("А", texts: ["было"])
        try await checkpoint.beforeWriting(page.id, agent: "codex")
        host.clock.advance(minutes: 5)
        try await checkpoint.beforeWriting(page.id, agent: "codex")
        #expect(try agentVersions(page.id).count == 1)
        host.clock.advance(minutes: 6)
        try await checkpoint.beforeWriting(page.id, agent: "codex")
        #expect(try agentVersions(page.id).count == 2)
    }

    @Test func checkpointCoversAgentWorkWithShortPauses() async throws {
        let page = try host.page("А", texts: ["было"])
        let executor = CommandExecutor(host: host, log: RecordingLog())
        func write(_ text: String) async {
            let response = await executor.run(ControlRequest(command: "page.write", args: ["page": .string(page.id.controlText), "markdown": .string(text)],
                                                             agent: "codex"))
            #expect(response.ok)
        }
        await write("1")
        host.clock.advance(minutes: 8)
        await write("2")
        host.clock.advance(minutes: 8)
        await write("3")
        #expect(try agentVersions(page.id).count == 1, "Работа агента с паузами меньше 10 минут разбита на несколько «до правки агента»")
        host.clock.advance(minutes: 11)
        await write("4")
        #expect(try agentVersions(page.id).count == 2)
    }

    @Test func renameAndLayoutRecordAgentVersion() async throws {
        let executor = CommandExecutor(host: host, log: RecordingLog())
        let page = try host.page("Старое название", texts: ["текст"])
        let renamed = await executor.run(ControlRequest(command: "page.rename", args: ["page": .string(page.id.controlText), "title": "Новое"],
                                                        agent: "codex"))
        #expect(renamed.ok)
        let version = try #require(try agentVersions(page.id).first, "page rename без версии «до правки агента»")
        #expect(try host.versions.snapshot(version.id)?.title == "Старое название")
        let narrow = try host.page("Узкая", texts: ["текст"])
        let widened = await executor.run(ControlRequest(command: "page.layout", args: ["page": .string(narrow.id.controlText), "fullWidth": "on"],
                                                        agent: "codex"))
        #expect(widened.ok)
        #expect(try agentVersions(narrow.id).count == 1, "page layout без версии «до правки агента»")
    }

    @Test func eachPageGetsItsOwn() async throws {
        let first = try host.page("А", texts: ["1"])
        let second = try host.page("Б", texts: ["2"])
        try await checkpoint.beforeWriting(first.id, agent: "codex")
        try await checkpoint.beforeWriting(second.id, agent: "claude")
        #expect(try agentVersions(first.id).count == 1)
        #expect(try agentVersions(second.id).first?.summary.agent == "claude")
    }

    @Test func versionHoldsStateBeforeEdit() async throws {
        let page = try host.page("А", texts: ["до правки"])
        try await checkpoint.beforeWriting(page.id, agent: "codex")
        try host.store.write { tx in
            var block = try tx.blocks(ofPage: page.id)[0]
            block.text = InlineText("после правки")
            try tx.updateBlock(block)
        }
        let version = try #require(try agentVersions(page.id).first)
        let snapshot = try #require(try host.versions.snapshot(version.id))
        #expect(snapshot.blocks.map(\.text.string) == ["до правки"])
    }

    @Test func versionEqualsWhatCommandSawBeforeEdit() async throws {
        let page = try host.page("А", texts: ["до правки"])
        let document = try host.openDocuments.open(page.id)
        defer { host.openDocuments.release(page.id) }
        let block = try #require(document.blocks.first)
        let seen = EventLog()
        let write: CommandHandler = { session in
            // Человек печатает в окне, пока команда готовит версию: версия — ровно то, что команда правит.
            Task { @MainActor in document.setText(InlineText("набрал человек"), ofBlock: block.id) }
            try await session.willWrite(page.id)
            seen.events = document.blocks.map(\.text.string)
            return CommandResult()
        }
        let executor = CommandExecutor(host: host, registry: HandlerRegistry(["page.write": write]), log: RecordingLog())
        let response = await executor.run(ControlRequest(command: "page.write", args: ["page": .string(page.id.controlText), "markdown": "x"],
                                                         agent: "codex"))
        #expect(response.ok)
        let version = try #require(try agentVersions(page.id).first)
        let snapshot = try #require(try host.versions.snapshot(version.id))
        #expect(snapshot.blocks.map(\.text.string) == seen.events)
    }

    @Test func storeMarksAgentStamps() async throws {
        let page = try host.page("А", texts: ["1"])
        try await checkpoint.beforeWriting(page.id, agent: "codex")
        let stamps = try #require(try host.versions.allVersionStamps()[page.id])
        #expect(stamps.contains { $0.isAgentCheckpoint })
    }

    @Test func pruningKeepsAgentVersions() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let agent = VersionStamp(id: UUID(), createdAt: base, isAgentCheckpoint: true)
        let later = VersionStamp(id: UUID(), createdAt: base.addingTimeInterval(600))
        let newest = VersionStamp(id: UUID(), createdAt: base.addingTimeInterval(5 * 86_400))
        let now = base.addingTimeInterval(5 * 86_400 + 60)
        #expect(VersionPruning.versionsToRemove([agent, later, newest], now: now).isEmpty)
        let plain = VersionStamp(id: UUID(), createdAt: base)
        #expect(VersionPruning.versionsToRemove([plain, later, newest], now: now) == [plain.id])
    }

    @Test func oldSummariesDecodeWithoutAgent() throws {
        let summary = try JSONDecoder().decode(VersionSummary.self, from: Data(#"{"blocksAdded":2}"#.utf8))
        #expect(summary.agent == nil)
        #expect(summary.lines == ["добавлено 2 блока"])
        let withAgent = try JSONDecoder().decode(VersionSummary.self, from: JSONEncoder().encode(VersionSummary(blocksAdded: 1, agent: "codex")))
        #expect(withAgent.agent == "codex")
        #expect(withAgent.lines == ["до правки агента (codex)", "добавлен 1 блок"])
    }
}
