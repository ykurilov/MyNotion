import Foundation
import NotesCore
import Testing
@testable import PageMarkdown

/// Блоки, скопированные в MyNotion, для других программ: Markdown простым текстом и HTML. Вставка их обратно
/// разбором ⌘V даёт те же виды блоков.
@Suite("Копирование блоков: Markdown и HTML")
struct CopiedBlocksTextTests {
    private static let pageId = UUID()
    private static let mentioned = UUID()
    private static let link = URL(string: "https://example.com/doc")!

    private static func blocks() -> [Block] {
        var key: FractionalSortKey?
        func block(_ kind: BlockKind, _ text: String, indent: Int = 0, checked: Bool = false, runs: [StyledRun] = []) -> Block {
            key = .between(key, nil)
            return Block(pageId: pageId, kind: kind, text: InlineText(text, runs: runs), indent: indent, isChecked: checked, sortKey: key!)
        }
        return [
            block(.heading2, "План"),
            block(.bulletItem, "первый пункт", runs: [StyledRun(start: 0, length: 6, style: .bold)]),
            block(.bulletItem, "вложенный", indent: 1),
            block(.numberedItem, "раз"),
            block(.checkbox, "сделано", checked: true),
            block(.checkbox, "потом"),
            block(.paragraph, "Ссылка и \u{FFFC}",
                  runs: [StyledRun(start: 0, length: 6, style: .link(link)), StyledRun(start: 9, length: 1, style: .mention(mentioned))]),
        ]
    }

    private static func title(_ id: UUID) -> String? { id == mentioned ? "Дневник" : nil }

    @Test("Markdown: заголовок, вложенный список, нумерация, задачи, жирный, ссылка; упоминание — названием")
    func markdown() {
        let markdown = CopiedBlocksText.markdown(for: Self.blocks(), pageTitle: Self.title)
        #expect(markdown.contains("## План"))
        #expect(markdown.contains("- **первый** пункт"))
        #expect(markdown.contains("  - вложенный"))
        #expect(markdown.contains("1. раз"))
        #expect(markdown.contains("- [x] сделано"))
        #expect(markdown.contains("- [ ] потом"))
        #expect(markdown.contains("[Ссылка](https://example.com/doc) и Дневник"))
        #expect(!markdown.contains("mynotion://"))
    }

    @Test("HTML: теги блоков, вложенный список внутри пункта, отметки задач, оформление и ссылка")
    func html() {
        let html = CopiedBlocksText.html(for: Self.blocks(), pageTitle: Self.title)
        #expect(html.contains("<h2>План</h2>"))
        #expect(html.contains("<ul><li><strong>первый</strong> пункт<ul><li>вложенный</li></ul></li></ul>"))
        #expect(html.contains("<ol><li>раз</li></ol>"))
        #expect(html.contains("<ul><li><input type=\"checkbox\" checked disabled> сделано</li><li><input type=\"checkbox\" disabled> потом</li></ul>"))
        #expect(html.contains("<p><a href=\"https://example.com/doc\">Ссылка</a> и Дневник</p>"))
    }

    @Test("HTML копии разбирается вставкой обратно в те же блоки")
    func htmlRoundTrip() throws {
        let html = CopiedBlocksText.html(for: Self.blocks(), pageTitle: Self.title)
        let blocks = try #require(PastedText.blocks(from: "", html: html, pageId: Self.pageId, hasRichText: true))
        #expect(blocks.map(\.kind) == [.heading2, .bulletItem, .bulletItem, .numberedItem, .checkbox, .checkbox, .paragraph])
        #expect(blocks.map(\.indent) == [0, 0, 1, 0, 0, 0, 0])
        #expect(blocks.map(\.isChecked) == [false, false, false, false, true, false, false])
        #expect(blocks[1].text.runs == [StyledRun(start: 0, length: 6, style: .bold)])
        #expect(blocks[6].text.runs == [StyledRun(start: 0, length: 6, style: .link(Self.link))])
    }

    @Test("Код с языком и таблица — в Markdown и HTML")
    func codeAndTable() {
        var props = BlockProps()
        props.language = "swift"
        let code = Block(pageId: Self.pageId, kind: .code, text: InlineText("let x = 1 < 2"), sortKey: .between(nil, nil), props: props)
        let markdown = CopiedBlocksText.markdown(for: [code], pageTitle: Self.title)
        #expect(markdown.contains("```swift\nlet x = 1 < 2\n```"))
        let html = CopiedBlocksText.html(for: [code], pageTitle: Self.title)
        #expect(html.contains("<pre><code class=\"language-swift\">let x = 1 &lt; 2</code></pre>"))
    }
}
