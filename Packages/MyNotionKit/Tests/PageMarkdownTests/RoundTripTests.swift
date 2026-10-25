import Foundation
import NotesCore
import PageEditor
import Testing
@testable import PageMarkdown

/// SC-404: «прочитать → записать → прочитать» даёт тот же Markdown на страницах эталона 001–004 и на `meeting.md`.
@Suite("Markdown страницы: прочитать → записать → прочитать")
struct RoundTripTests {
    static let planId = UUID(uuidString: "00000000-0000-4000-8000-0000000000aa")!

    @Test("meeting.md: все виды блоков, чтение — тот же файл")
    func meeting() throws {
        let fixture = try PageMarkdownFixture()
        try fixture.page(title: "План проекта", id: Self.planId)
        let markdown = try String(contentsOf: PageMarkdownFixture.fixtures.appendingPathComponent("meeting.md"), encoding: .utf8)
        let pageId = try fixture.page(title: "Встреча 24.10", markdown: markdown)
        let blocks = try fixture.blocks(of: pageId)
        let kinds = Set(blocks.map(\.kind))
        for kind: BlockKind in [.heading1, .heading2, .heading3, .paragraph, .bulletItem, .numberedItem, .checkbox, .code, .quote,
                                .callout, .toggle, .table, .equation, .divider, .pageLink] {
            #expect(kinds.contains(kind), "нет блока \(kind)")
        }
        #expect(blocks.contains { $0.kind == .bulletItem && $0.indent == 1 })
        #expect(blocks.first { $0.kind == .code }?.props.language == "swift")
        #expect(blocks.first { $0.kind == .pageLink }?.linkedPageId == Self.planId)
        let (first, second) = try fixture.roundTrip(pageId)
        #expect(first.trimmingCharacters(in: .newlines) == markdown.trimmingCharacters(in: .newlines))
        #expect(second == first)
    }

    @Test("001: страницы эталонной базы, включая страницу на 1 000 блоков")
    func referenceLibrary() throws {
        let fixture = try PageMarkdownFixture()
        try ReferenceLibraryGenerator().generate(into: fixture.store)
        let outline = try fixture.store.pageOutline()
        var counts: [UUID: Int] = [:]
        for page in outline { counts[page.id] = try fixture.blocks(of: page.id).count }
        let largest = try #require(counts.max { $0.value < $1.value }?.key)
        let sample = [largest] + outline.enumerated().filter { $0.offset % 97 == 0 }.map(\.element.id)
        for pageId in sample {
            let (first, second) = try fixture.roundTrip(pageId)
            #expect(second == first, "страница \(pageId)")
        }
    }

    @Test("002: «богатая» страница со всеми блоками и строка со всеми оформлениями")
    func richPage() throws {
        let fixture = try PageMarkdownFixture()
        let richId = try RichPageGenerator(parts: BlockKinds.richPageParts).ensure(in: fixture.store)
        let inlineId = UUID.timeOrdered()
        try fixture.store.write { transaction in
            try transaction.insertPage(Page(id: inlineId, title: "Оформление в строке", sortKey: .between(nil, nil), createdAt: Date(), updatedAt: Date()))
            var key: FractionalSortKey?
            for text in Self.inlineSamples(mentioning: richId) {
                key = .between(key, nil)
                try transaction.insertBlock(Block(pageId: inlineId, kind: .paragraph, text: text, sortKey: key!))
            }
        }
        for pageId in [richId, inlineId] {
            let (first, second) = try fixture.roundTrip(pageId)
            #expect(!first.isEmpty)
            #expect(second == first)
        }
        let rebuilt = try fixture.builder().blocks(fromMarkdown: try fixture.reader().markdown(for: try fixture.blocks(of: inlineId)),
                                                    pageId: inlineId).blocks
        #expect(rebuilt.contains { $0.text.runs.contains { $0.style == .mention(richId) } })
    }

    @Test("003: страницы дополнений навигации — ссылки на подстраницы, обложки, шаблоны")
    func pagesNavigation() throws {
        let fixture = try PageMarkdownFixture()
        try PagesNavigationSample(imageProps: BlockProps()).ensure(in: fixture.store)
        let outline = try fixture.store.pageOutline()
        #expect(outline.count > 10)
        for page in outline.prefix(60) {
            let (first, second) = try fixture.roundTrip(page.id)
            #expect(second == first, "страница «\(page.title)»")
        }
    }

    @Test("004: обзор со встроенной базой и строки баз")
    func databases() throws {
        let fixture = try PageMarkdownFixture()
        let sample = try DatabaseSampleGenerator(taskCount: 40, projectCount: 5).ensure(in: fixture.store)
        let overview = try fixture.blocks(of: sample.overviewId)
        #expect(overview.contains { $0.kind == .database })
        let rows = try fixture.store.pageOutline().filter { $0.parentId == sample.tasksId }.prefix(5).map(\.id)
        for pageId in [sample.overviewId] + rows {
            let (first, second) = try fixture.roundTrip(pageId)
            #expect(second == first)
        }
        let rebuilt = try fixture.builder().blocks(fromMarkdown: try fixture.reader().markdown(for: overview), pageId: sample.overviewId).blocks
        #expect(rebuilt.contains { $0.kind == .database && $0.linkedPageId == sample.inlineTasksId })
    }

    static func inlineSamples(mentioning pageId: UUID) -> [InlineText] {
        func text(_ parts: [(String, InlineStyle?)]) -> InlineText {
            var string = ""
            var runs: [StyledRun] = []
            for (fragment, style) in parts {
                let length = (fragment as NSString).length
                if let style { runs.append(StyledRun(start: (string as NSString).length, length: length, style: style)) }
                string += fragment
            }
            return InlineText(string, runs: runs).normalized()
        }
        let atom = "\u{FFFC}"
        return [
            text([("Обычный, ", nil), ("жирный", .bold), (", ", nil), ("курсив", .italic), (", ", nil), ("зачёркнутый", .strikethrough),
                  (", ", nil), ("подчёркнутый", .underline), (", ", nil), ("код", .code), (" и ", nil),
                  ("ссылка", .link(URL(string: "https://example.com/a?b=1")!)), (".", nil)]),
            text([("Красный текст", .textColor(.red)), (" и ", nil), ("жёлтый фон", .backgroundColor(.yellow)), (".", nil)]),
            text([("Смотри ", nil), (atom, .mention(pageId)), (" сегодня.", nil)]),
            text([("Срок ", nil), (atom, .date(DateMention(start: "2026-10-21", includesTime: false, timeZone: "Asia/Makassar"))), (".", nil)]),
            text([("Формула ", nil), (atom, .equation("E = mc^2")), (" в строке, цена $5 и $10.", nil)]),
        ]
    }
}
