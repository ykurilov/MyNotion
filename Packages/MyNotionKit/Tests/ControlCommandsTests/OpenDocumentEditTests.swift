import ControlProtocol
import Foundation
import Testing
@testable import ControlCommands
@testable import NotesCore

/// Правка агента в странице, открытой в окне с незаписанным вводом человека (T031): обе правки целы в документе
/// окна и на диске.
@MainActor @Suite struct OpenDocumentEditTests {
    let host: TestHost
    let executor: CommandExecutor

    init() throws {
        host = try TestHost()
        executor = CommandExecutor(host: host, registry: HandlerRegistry(PageHandlers.all), log: RecordingLog())
    }

    func append(_ markdown: String, to pageId: UUID) async throws {
        let response = await executor.run(ControlRequest(command: "page.append",
                                                         args: ["page": .string(pageId.controlText), "markdown": .string(markdown)]))
        try #require(response.ok, "\(response.error?.message ?? "")")
    }

    @Test func appendKeepsUnsavedUserEdit() async throws {
        let page = try host.page("Встреча", texts: ["черновик"])
        let document = try host.openDocuments.open(page.id)
        defer { host.openDocuments.release(page.id) }
        let draft = try #require(document.blocks.first)
        document.setText(InlineText("набрал человек"), ofBlock: draft.id)
        #expect(document.hasUnsavedChanges)

        try await append("- [ ] позвонить", to: page.id)

        #expect(document.blocks.map(\.text.string) == ["набрал человек", "позвонить"])
        #expect(document.blocks.last?.kind == .checkbox)
        #expect(try host.texts(page.id) == ["набрал человек", "позвонить"])
    }

    /// Человек и агент по очереди правят открытую страницу: ни одна правка не теряется.
    @Test func hundredAlternationsLoseNothing() async throws {
        try await alternate(steps: 100)
    }

    /// Тот же сценарий на 1 000 шагов — медленная группа (`MYNOTION_PERF=1`, scripts/imac/perf-tests.zsh).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MYNOTION_PERF"] != nil))
    func thousandAlternationsLoseNothingFullScale() async throws {
        try await alternate(steps: 1000)
    }

    private func alternate(steps: Int) async throws {
        let page = try host.page("Журнал", texts: ["0"])
        let document = try host.openDocuments.open(page.id)
        defer { host.openDocuments.release(page.id) }
        let draft = try #require(document.blocks.first)
        for step in 1...steps {
            document.setText(InlineText("человек \(step)"), ofBlock: draft.id)
            try await append("агент \(step)", to: page.id)
        }
        let expected = ["человек \(steps)"] + (1...steps).map { "агент \($0)" }
        #expect(document.blocks.map(\.text.string) == expected)
        host.openDocuments.saveAll()
        #expect(try host.texts(page.id) == expected)
    }
}
