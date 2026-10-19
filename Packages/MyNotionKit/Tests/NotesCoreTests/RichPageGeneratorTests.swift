import Foundation
import GRDB
import Testing
@testable import NotesCore

/// Эталонная «богатая» страница (quickstart.md): 1 000 блоков потока страницы; каждый тип добавляет свою часть.
@MainActor
@Suite("Богатая страница")
struct RichPageGeneratorTests {
    let folder: TemporaryFolder
    let store: NotesStore

    init() throws {
        folder = try TemporaryFolder()
        store = try NotesStore(database: AppDatabase.open(at: folder.databaseURL), clock: HybridLogicalClock(deviceId: UUID()))
    }

    /// Часть типа с переключателем (свёрнут), колонками и цветом.
    static let part: RichPagePart = {
        let columnId = UUID()
        return RichPagePart(name: "проба", blocks: [
            RichBlockSpec(.toggle, "Свёрнутый переключатель", isCollapsed: true),
            RichBlockSpec(.paragraph, "Ребёнок", indent: 1),
            RichBlockSpec(.columnList, contained: [
                RichBlockSpec(.column, id: columnId, contained: [RichBlockSpec(.paragraph, "В колонке")]),
                RichBlockSpec(.column, contained: [RichBlockSpec(.paragraph, "Во второй")]),
            ]),
            RichBlockSpec(.callout, "Выноска", color: BlockColor(background: .gray)),
        ])
    }()

    @Test("1 000 блоков потока страницы: части типов и заполнение текстом; цвета на 100 блоках")
    func generatesThousandBlocks() throws {
        let pageId = try RichPageGenerator(parts: [Self.part]).ensure(in: store)
        let content = try #require(try store.pageContent(pageId))
        let document = PageDocument(content: content)
        let pageFlow = content.blocks.filter { $0.containerId == nil }
        #expect(pageFlow.count == RichPageGenerator.blockCount)
        #expect(content.page.title == RichPageGenerator.title)
        #expect(pageFlow.filter { !$0.color.isNone }.count >= 100)
        #expect(pageFlow.contains { $0.kind == .toggle && $0.text.string == "Свёрнутый переключатель" })
        let list = try #require(pageFlow.first { $0.kind == .columnList })
        #expect(document.flow(list.id).count == 2)
        #expect(document.flow(document.flow(list.id)[0].id).map(\.text.string) == ["В колонке"])
        #expect(Set(pageFlow.map(\.kind)).isSuperset(of: [.paragraph, .heading1, .heading2, .bulletItem, .numberedItem, .checkbox]))
    }

    @Test("Свёрнутость пишется в block_view_state этого Mac")
    func collapsedStateStored() throws {
        let pageId = try RichPageGenerator(parts: [Self.part]).ensure(in: store)
        let toggle = try #require(try store.pageContent(pageId)?.blocks.first { $0.kind == .toggle })
        let collapsed = try store.database.dbWriter.read { db in
            try Bool.fetchOne(db, sql: "SELECT isCollapsed FROM block_view_state WHERE blockId = ?", arguments: [toggle.id.uuidString.lowercased()])
        }
        #expect(collapsed == true)
    }

    @Test("Повторный вызов страницу не дублирует")
    func ensureIsIdempotent() throws {
        let generator = RichPageGenerator(parts: [Self.part])
        let first = try generator.ensure(in: store)
        #expect(try generator.ensure(in: store) == first)
        #expect(try store.pageOutline().filter { $0.title == RichPageGenerator.title }.count == 1)
    }
}
