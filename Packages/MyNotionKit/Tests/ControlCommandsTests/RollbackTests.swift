import ControlProtocol
import Foundation
import Testing
@testable import ControlCommands
@testable import NotesCore

/// Откат неудачного пакета возвращает только сделанное командой: ввод человека в окне после правки агента остаётся.
@MainActor @Suite struct RollbackTests {
    let host: TestHost
    let page: Page

    init() throws {
        host = try TestHost()
        page = try host.page("Заметки", texts: ["первый", "второй"])
    }

    /// Пакет, последний шаг которого печатает в окне за человека и падает: ввод попадает между правкой агента и откатом.
    func batch(_ steps: [ControlJSON], typing: @escaping @MainActor (PageDocument) -> Void) async -> ControlResponse {
        let pageId = page.id
        let typeAndFail: CommandHandler = { session in
            let document = try session.host.openDocuments.open(pageId)
            defer { session.host.openDocuments.release(pageId) }
            typing(document)
            throw ControlError(.invalidValue, "Шаг упал")
        }
        let registry = HandlerRegistry(HandlerRegistry.standard.handlers.merging(["page.layout": typeAndFail]) { _, own in own })
        let executor = CommandExecutor(host: host, registry: registry, log: RecordingLog())
        let failing: ControlJSON = ["command": "page.layout", "args": ["page": .string(page.id.controlText), "fullWidth": "on"]]
        return await executor.run(ControlRequest(command: "batch", args: ["steps": .array(steps + [failing])], agent: "codex"))
    }

    @Test func rollbackKeepsBlockTypedIntoAfterUpdate() async throws {
        let document = try host.openDocuments.open(page.id)
        defer { host.openDocuments.release(page.id) }
        let first = try #require(document.blocks.first)
        let second = try #require(document.blocks.last)
        let response = await batch([
            ["command": "block.update", "args": ["block": .string(first.id.controlText), "text": "агент"]],
            ["command": "block.update", "args": ["block": .string(second.id.controlText), "text": "агент 2"]],
        ]) { document in document.setText(InlineText("агент и человек"), ofBlock: first.id) }
        #expect(response.error?.code == .batchFailed)
        host.openDocuments.saveAll()
        #expect(try host.texts(page.id) == ["агент и человек", "второй"], "Откат стёр ввод человека или не вернул нетронутый блок")
        #expect(response.warnings.contains { $0.code == .partialRollback })
    }

    @Test func rollbackOfWriteKeepsBlockTypedInto() async throws {
        _ = try host.openDocuments.open(page.id)
        defer { host.openDocuments.release(page.id) }
        let response = await batch([
            ["command": "page.write", "args": ["page": .string(page.id.controlText), "markdown": "агент"]],
        ]) { document in
            guard let written = document.allBlocks.first(where: { $0.text.string == "агент" }) else { return }
            document.setText(InlineText("агент и человек"), ofBlock: written.id)
        }
        #expect(response.error?.code == .batchFailed)
        host.openDocuments.saveAll()
        #expect(Set(try host.texts(page.id)) == ["первый", "второй", "агент и человек"], "Откат стёр абзац, в котором печатал человек")
    }

    @Test func untouchedRollbackHasNoWarning() async throws {
        let document = try host.openDocuments.open(page.id)
        defer { host.openDocuments.release(page.id) }
        let first = try #require(document.blocks.first)
        let response = await batch([
            ["command": "block.update", "args": ["block": .string(first.id.controlText), "text": "агент"]],
        ]) { _ in }
        #expect(response.error?.code == .batchFailed)
        #expect(try host.texts(page.id) == ["первый", "второй"])
        #expect(response.warnings.isEmpty)
    }
}
