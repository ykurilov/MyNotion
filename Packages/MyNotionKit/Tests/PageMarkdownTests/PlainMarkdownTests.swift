import Foundation
import NotesCore
import NotionImport
import Testing
@testable import PageMarkdown

/// Markdown агента (`.plainMarkdown`, research R7, FR-414): не файл выгрузки Notion.
@Suite("Markdown агента")
struct PlainMarkdownTests {
    @Test("Первая «# » — заголовок, а не название страницы")
    func firstHeadingStaysHeading() {
        let page = NotionMarkdownParser(options: .plainMarkdown).parse("# План\n\nТекст")
        #expect(page.title == nil)
        #expect(page.blocks.map(\.kind) == [.heading1, .paragraph])
        #expect(NotionMarkdownParser().parse("# План\n\nТекст").title == "План")
    }

    @Test("HTML-блок и сноска — абзацем как есть и предупреждением со строкой")
    func unsupportedBecomesTextWithWarning() throws {
        let fixture = try PageMarkdownFixture()
        let markdown = "Первая строка\n\n<div class=\"note\">Внутри</div>\n\nТекст со сноской[^1]\n\n[^1]: Пояснение"
        let result = try fixture.builder().blocks(fromMarkdown: markdown, pageId: UUID())
        #expect(result.blocks.map(\.kind) == [.paragraph, .paragraph, .paragraph, .paragraph])
        #expect(result.blocks[1].text.string == "<div class=\"note\">Внутри</div>")
        #expect(result.blocks[3].text.string == "[^1]: Пояснение")
        #expect(result.warnings.map(\.line) == [3, 7])
    }

    @Test("Картинка по своему пути — вложение; по https — закладка с адресом и предупреждение")
    func images() throws {
        let fixture = try PageMarkdownFixture()
        let image = fixture.folder.appendingPathComponent("схема.png")
        try Self.png.write(to: image)
        let markdown = "![Схема](схема.png)\n\n![Логотип](https://example.com/logo.png)"
        let result = try fixture.builder(baseFolder: fixture.folder).blocks(fromMarkdown: markdown, pageId: UUID())
        #expect(result.blocks.map(\.kind) == [.image, .bookmark])
        let ref = try #require(result.blocks[0].props.attachment)
        #expect(ref.name == "схема.png")
        #expect(fixture.attachments.fileURL(for: ref.id) != nil)
        #expect(result.blocks[0].text.string == "Схема")
        #expect(result.blocks[1].props.url == URL(string: "https://example.com/logo.png"))
        #expect(result.blocks[1].props.title == "Логотип")
        #expect(result.warnings.map(\.line) == [3])
    }

    @Test("Файла по пути нет — «[файл: имя]» и предупреждение")
    func missingFile() throws {
        let fixture = try PageMarkdownFixture()
        let result = try fixture.builder(baseFolder: fixture.folder).blocks(fromMarkdown: "![Нет](нет.png)", pageId: UUID())
        #expect(result.blocks.map(\.text.string) == ["[файл: нет.png]"])
        #expect(result.warnings.count == 1)
    }

    @Test("Пустой Markdown — пустая страница")
    func emptyMarkdown() throws {
        let fixture = try PageMarkdownFixture()
        #expect(try fixture.builder().blocks(fromMarkdown: "", pageId: UUID()).blocks.isEmpty)
        #expect(try fixture.builder().blocks(fromMarkdown: "\n\n", pageId: UUID()).blocks.isEmpty)
    }

    @Test("Ссылка на неизвестную страницу — название простым текстом")
    func unknownPageLink() throws {
        let fixture = try PageMarkdownFixture()
        let known = try fixture.page(title: "Есть")
        let markdown = "[Нет такой](mynotion://page/\(UUID().uuidString))\n\nСм. [Есть](mynotion://page/\(known.uuidString)) и [Нет](mynotion://page/\(UUID().uuidString))"
        let result = try fixture.builder().blocks(fromMarkdown: markdown, pageId: UUID())
        #expect(result.blocks.map(\.kind) == [.paragraph, .paragraph])
        #expect(result.blocks[0].text.string == "Нет такой")
        #expect(result.blocks[0].text.runs.isEmpty)
        #expect(result.blocks[1].text.runs.map(\.style) == [.mention(known)])
        #expect(result.blocks[1].text.string == "См. \u{FFFC} и Нет")
        #expect(!result.warnings.isEmpty)
    }

    /// Картинка 1×1 PNG.
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==")!
}
