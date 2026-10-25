import ControlProtocol
import Foundation
import Testing
@testable import ControlCommands
@testable import NotesCore

/// Блоки внутри колонок и таблиц (не в потоке страницы): команды видят их соседей, вложения и содержимое при замене.
@MainActor @Suite struct ContentOutsideFlowTests {
    let host: TestHost
    let executor: CommandExecutor

    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!

    init() throws {
        host = try TestHost()
        executor = CommandExecutor(host: host, log: RecordingLog())
    }

    @discardableResult
    func ok(_ command: String, _ args: [String: ControlJSON] = [:], sourceLocation: SourceLocation = #_sourceLocation) async throws -> ControlJSON {
        let response = await executor.run(ControlRequest(command: command, args: args, agent: "codex", cwd: host.folder.url.path))
        try #require(response.ok, "\(command): \(response.error?.code.rawValue ?? "") \(response.error?.message ?? "")", sourceLocation: sourceLocation)
        return try #require(response.data, sourceLocation: sourceLocation)
    }

    /// Страница с колонкой из трёх абзацев «а», «б», «в» (колонки и блоки внутри — вне потока страницы).
    func pageWithColumn() throws -> (page: Page, column: UUID, paragraphs: [UUID]) {
        let page = try host.page("Колонки")
        let list = Block(pageId: page.id, kind: .columnList, sortKey: .between(nil, nil))
        let column = Block(pageId: page.id, kind: .column, sortKey: .between(nil, nil), containerId: list.id)
        var key: FractionalSortKey?
        let paragraphs = ["а", "б", "в"].map { text -> Block in
            key = .between(key, nil)
            return Block(pageId: page.id, text: InlineText(text), sortKey: key!, containerId: column.id)
        }
        try host.store.write { tx in
            for block in try tx.blocks(ofPage: page.id) { try tx.deleteBlock(block.id) }
            for block in [list, column] + paragraphs { try tx.insertBlock(block) }
        }
        return (page, column.id, paragraphs.map(\.id))
    }

    /// Тексты блоков колонки по порядку; ключи порядка не совпадают.
    func column(_ id: UUID, of page: Page) throws -> (texts: [String], keysAreDistinct: Bool) {
        let blocks = try #require(try host.store.pageContent(page.id)).blocks.filter { $0.containerId == id }.sorted { $0.sortKey < $1.sortKey }
        return (blocks.map { $0.kind == .paragraph ? $0.text.string : $0.kind.rawValue }, Set(blocks.map(\.sortKey)).count == blocks.count)
    }

    @discardableResult
    func file(_ name: String, _ data: Data) throws -> URL {
        let url = host.folder.url.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    @Test func attachmentAddedAfterBlockInColumnLandsNextToIt() async throws {
        let (page, column, paragraphs) = try pageWithColumn()
        try file("схема.png", Self.png)
        try await ok("attachment.add", ["page": .string(page.id.controlText), "file": "схема.png", "after": .string(paragraphs[0].controlText)])
        let result = try self.column(column, of: page)
        #expect(result.texts == ["а", "image", "б", "в"])
        #expect(result.keysAreDistinct)
    }

    @Test func appendAfterBlockInColumnLandsNextToIt() async throws {
        let (page, column, paragraphs) = try pageWithColumn()
        try await ok("page.append", ["page": .string(page.id.controlText), "markdown": "новый", "after": .string(paragraphs[0].controlText)])
        let result = try self.column(column, of: page)
        #expect(result.texts == ["а", "новый", "б", "в"])
        #expect(result.keysAreDistinct)
    }

    @Test func attachmentListOfOpenPageIncludesColumnFiles() async throws {
        let (page, _, paragraphs) = try pageWithColumn()
        try file("схема.png", Self.png)
        try await ok("attachment.add", ["page": .string(page.id.controlText), "file": "схема.png", "after": .string(paragraphs[0].controlText)])
        let document = try host.openDocuments.open(page.id)
        defer { host.openDocuments.release(document.pageId) }
        let items = try #require(try await ok("attachment.list", ["page": .string(page.id.controlText)])["items"]?.array)
        #expect(items.count == 1, "Файл в колонке открытой страницы не показан")
    }

    @Test func writeReplacesTableAndColumnsWithAllTheirBlocks() async throws {
        let (page, _, _) = try pageWithColumn()
        try await ok("page.append", ["page": .string(page.id.controlText), "markdown": "| А | Б |\n| --- | --- |\n| 1 | 2 |"])
        try #require(try #require(try host.store.pageContent(page.id)).blocks.contains { $0.kind == .tableCell })
        try await ok("page.write", ["page": .string(page.id.controlText), "markdown": "Один абзац"])
        let blocks = try #require(try host.store.pageContent(page.id)).blocks
        #expect(blocks.map(\.text.string) == ["Один абзац"], "После замены остались блоки таблицы или колонок: \(blocks.map(\.kind.rawValue))")
        #expect(host.openDocuments.document(for: page.id) == nil)
    }

    @Test func writeKeepsKnownAttachmentInColumn() async throws {
        let (page, _, paragraphs) = try pageWithColumn()
        try file("схема.png", Self.png)
        try await ok("attachment.add", ["page": .string(page.id.controlText), "file": "схема.png", "after": .string(paragraphs[0].controlText)])
        let before = try #require(try await ok("attachment.list", ["page": .string(page.id.controlText)])["items"]?.array?.first?["id"]?.string)
        let markdown = try #require(try await ok("page.read", ["page": .string(page.id.controlText)])["markdown"]?.string)
        try await ok("page.write", ["page": .string(page.id.controlText), "markdown": .string(markdown)])
        let after = try await ok("attachment.list", ["page": .string(page.id.controlText)])["items"]?.array?.compactMap { $0["id"]?.string }
        #expect(after == [before], "Файл из колонки при записи того же Markdown импортирован заново")
    }
}
