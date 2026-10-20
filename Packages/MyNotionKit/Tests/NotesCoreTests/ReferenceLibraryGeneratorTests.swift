import Foundation
import GRDB
import Testing
@testable import NotesCore

@Suite("Эталонная база и страница-образец")
struct ReferenceLibraryGeneratorTests {
    @Test("Эталон: 1 000 страниц до 10 уровней, 100 000 блоков всех типов, одна страница на 1 000 блоков")
    func referenceLibraryShape() throws {
        let folder = try TemporaryFolder()
        try ReferenceLibraryGenerator().generate(at: folder.databaseURL)

        let database = try AppDatabase.open(at: folder.databaseURL)
        let store = NotesStore(database: database, clock: HybridLogicalClock(deviceId: UUID()))
        let pages = try store.pageOutline()
        #expect(pages.count == 1_000)

        let parents = Dictionary(uniqueKeysWithValues: pages.map { ($0.id, $0.parentId) })
        func levels(_ id: UUID) -> Int {
            var count = 1
            var current = parents[id] ?? nil
            while let parent = current {
                count += 1
                current = parents[parent] ?? nil
            }
            return count
        }
        #expect(pages.map { levels($0.id) }.max() == 10)

        let stats = try database.dbWriter.read { db in
            (
                blocks: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM block WHERE isDeleted = 0")!,
                kinds: try String.fetchSet(db, sql: "SELECT DISTINCT kind FROM block"),
                blocksPerPage: try Int.fetchAll(db, sql: "SELECT COUNT(*) FROM block GROUP BY pageId ORDER BY 1 DESC"),
                pageLinks: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM block WHERE kind = 'pageLink'")!,
                linkedChildren: try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM page child
                    JOIN block link ON link.linkedPageId = child.id AND link.pageId = child.parentId
                    """)!,
                sampleText: try String.fetchAll(db, sql: "SELECT text FROM block LIMIT 2000").joined(separator: " ")
            )
        }
        #expect(stats.blocks == 100_000)
        // Эталон 001 — блоки 001; блоки 002 — на «богатой» странице (RichPageGenerator).
        #expect(stats.kinds == ["paragraph", "heading1", "heading2", "heading3", "bulletItem", "numberedItem", "checkbox", "pageLink"])
        #expect(stats.blocksPerPage.first == 1_000)
        #expect(stats.blocksPerPage.dropFirst().allSatisfy { $0 < 1_000 })
        #expect(stats.blocksPerPage.count == 1_000)

        // Подстраница — пара «страница с родителем + блок-ссылка в родителе».
        let childPages = pages.filter { $0.parentId != nil }.count
        #expect(stats.pageLinks == childPages)
        #expect(stats.linkedChildren == childPages)

        #expect(stats.sampleText.contains { ("а"..."я").contains($0) })
        #expect(stats.sampleText.contains { ("a"..."z").contains($0) })

        // Условие замеров (research R13): при запуске открыта страница на 1 000 блоков.
        let openPageId = try #require(try store.windowState(WindowState.mainWindowId)?.openPageId)
        #expect(try store.pageContent(openPageId)?.blocks.count == 1_000)
    }

    @Test("Генератор не трогает уже существующий файл")
    func refusesToOverwrite() throws {
        let folder = try TemporaryFolder()
        try Data("чужой файл".utf8).write(to: folder.databaseURL)

        #expect(throws: ReferenceLibraryGenerator.GenerationError.self) {
            try ReferenceLibraryGenerator().generate(at: folder.databaseURL)
        }
        #expect(try String(contentsOf: folder.databaseURL, encoding: .utf8) == "чужой файл")
    }

    @Test("Страница «MyNotion — образец» повторяет снимки Notion и не дублируется")
    func visualSamplePage() throws {
        let folder = try TemporaryFolder()
        let store = try NotesStore(database: AppDatabase.open(at: folder.databaseURL), clock: HybridLogicalClock(deviceId: UUID()))

        let sample = try VisualSamplePage.ensure(in: store)
        let again = try VisualSamplePage.ensure(in: store)
        #expect(again.id == sample.id)

        #expect(sample.title == "MyNotion — образец")
        #expect(sample.icon == "📘")
        let parentId = try #require(sample.parentId)
        let parent = try #require(try store.pageContent(parentId)?.page)
        #expect(parent.title == "Буфер")

        let blocks = try #require(try store.pageContent(sample.id)).blocks
        let outline = blocks.map { "\($0.kind.rawValue):\($0.indent)\($0.isChecked ? "✓" : "")" }
        #expect(outline == [
            "paragraph:0",
            "heading1:0", "paragraph:0",
            "heading2:0", "paragraph:0",
            "heading3:0", "paragraph:0",
            "bulletItem:0", "bulletItem:0", "bulletItem:1", "bulletItem:2", "bulletItem:0",
            "numberedItem:0", "numberedItem:0", "numberedItem:1", "numberedItem:0",
            "checkbox:0", "checkbox:0✓", "checkbox:0", "checkbox:1",
            "paragraph:0",
            "pageLink:0", "pageLink:0",
        ])

        let styles = Set(blocks[0].text.runs.map(\.style))
        #expect(styles.contains(.bold) && styles.contains(.italic) && styles.contains(.strikethrough) && styles.contains(.code))
        #expect(styles.contains { if case .link = $0 { true } else { false } })

        let subpages = try store.pageOutline().filter { $0.parentId == sample.id }
        #expect(subpages.map(\.title) == ["Подстраница первая", "Подстраница без иконки"])
        #expect(subpages.map(\.icon) == ["📝", nil])
        #expect(try store.pageOutline().count == 4)
    }
}
