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
