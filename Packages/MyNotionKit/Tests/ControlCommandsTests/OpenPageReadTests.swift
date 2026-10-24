import ControlProtocol
import Foundation
import Testing
@testable import ControlCommands
@testable import NotesCore

/// Чтение страницы, открытой в окне (сценарий A, шаг 4): таблица, её строки и ячейки не пропадают из `page read`.
@MainActor @Suite struct OpenPageReadTests {
    let host: TestHost
    let executor: CommandExecutor

    init() throws {
        host = try TestHost()
        executor = CommandExecutor(host: host, log: RecordingLog())
    }

    func ok(_ command: String, _ args: [String: ControlJSON]) async throws -> ControlJSON {
        let response = await executor.run(ControlRequest(command: command, args: args, agent: "e2e"))
        try #require(response.ok, "\(command): \(response.error?.message ?? "")")
        return try #require(response.data)
    }

    @Test func tableOfOpenPageIsReadInMarkdownAndJson() async throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PageMarkdownTests/Fixtures/meeting.md")
        let markdown = try String(contentsOf: fixture, encoding: .utf8)
            .replacingOccurrences(of: "00000000-0000-4000-8000-0000000000aa", with: UUID().uuidString.lowercased())
        let page = try #require(try await ok("page.create", ["title": "Т", "markdown": .string(markdown)])["page"]?["id"]?.string)
        let closed = try #require(try await ok("page.read", ["page": .string(page)])["markdown"]?.string)
        #expect(closed.contains("| Аня | Сборка | Четверг |"))

        let document = try host.openDocuments.open(try #require(UUID(uuidString: page)))
        defer { host.openDocuments.release(document.pageId) }
        let open = try #require(try await ok("page.read", ["page": .string(page)])["markdown"]?.string)
        #expect(open == closed)
        let blocks = try #require(try await ok("page.read", ["page": .string(page), "format": "json"])["blocks"]?.array)
        let table = try #require(blocks.first { $0["kind"] == "table" })
        #expect(table["children"]?.array?.isEmpty == false)
    }
}
