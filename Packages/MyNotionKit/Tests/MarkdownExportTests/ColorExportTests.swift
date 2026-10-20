import Foundation
import Testing
import NotesCore
@testable import MarkdownExport

/// Цвета в Markdown (FR-112; contracts/markdown-and-notion.md): текст — `<span data-color>`, фон — `<mark data-color>`,
/// цвет блока — строка-комментарий перед блоком.
@Suite("Цвета в Markdown")
struct ColorExportTests {
    private let pageId = UUID()
    private let writer = MarkdownBlockWriter()

    private func block(_ kind: BlockKind, _ text: String, runs: [StyledRun] = [], color: BlockColor = .none) -> Block {
        Block(pageId: pageId, kind: kind, text: InlineText(text, runs: runs), sortKey: .between(nil, nil), color: color)
    }

    private func block(_ text: String, runs: [StyledRun] = [], color: BlockColor = .none) -> Block {
        block(.paragraph, text, runs: runs, color: color)
    }

    private func markdown(_ blocks: Block...) -> String { writer.markdown(for: blocks, resolveLink: { _ in nil }) }

    private func run(_ start: Int, _ length: Int, _ style: InlineStyle) -> StyledRun {
        StyledRun(start: start, length: length, style: style)
    }

    // MARK: В строке

    @Test("Цвет текста — span с data-color")
    func textColor() {
        #expect(markdown(block("Это слово тут", runs: [run(4, 5, .textColor(.red))])) == "Это <span data-color=\"red\">слово</span> тут\n")
    }

    @Test("Цвет фона — mark с data-color")
    func backgroundColor() {
        #expect(markdown(block("Это слово тут", runs: [run(4, 5, .backgroundColor(.yellow))])) == "Это <mark data-color=\"yellow\">слово</mark> тут\n")
    }

    @Test("Оба цвета на одном тексте: фон снаружи, текст внутри")
    func bothColorsNest() {
        let text = markdown(block("слово", runs: [run(0, 5, .textColor(.red)), run(0, 5, .backgroundColor(.yellow))]))
        #expect(text == "<mark data-color=\"yellow\"><span data-color=\"red\">слово</span></mark>\n")
    }

    @Test("Цвета с жирным и ссылкой не теряют ни одного оформления")
    func colorWithOtherStyles() {
        let url = URL(string: "https://example.com")!
        let text = markdown(block("слово", runs: [run(0, 5, .bold), run(0, 5, .textColor(.blue)), run(0, 5, .link(url))]))
        #expect(text.contains("<span data-color=\"blue\">"))
        #expect(text.contains("**слово**"))
        #expect(text.contains("(https://example.com)"))
    }

    @Test("Цвет на части жирного текста: границы цвета не двигаются")
    func colorInsideBold() {
        let text = markdown(block("аб вг", runs: [run(0, 5, .bold), run(3, 2, .textColor(.green))]))
        #expect(text.contains("<span data-color=\"green\">вг</span>"))
        #expect(text.contains("**"))
    }

    @Test("Соседние куски разных цветов — отдельные теги")
    func adjacentColors() {
        let text = markdown(block("абвг", runs: [run(0, 2, .textColor(.red)), run(2, 2, .textColor(.blue))]))
        #expect(text == "<span data-color=\"red\">аб</span><span data-color=\"blue\">вг</span>\n")
    }

    @Test("Знаки Markdown внутри цветного текста экранируются как обычно")
    func escapingInsideColor() {
        #expect(markdown(block("a*b", runs: [run(0, 3, .textColor(.pink))])) == "<span data-color=\"pink\">a\\*b</span>\n")
    }

    // MARK: Цвет блока

    @Test("Цвет блока — комментарий перед ним")
    func blockColorComment() {
        let text = markdown(block("Важное", color: BlockColor(text: .red, background: .yellow)))
        #expect(text == "<!-- mynotion:color text=\"red\" background=\"yellow\" -->\nВажное\n")
    }

    @Test("Только фон или только текст — только этот атрибут")
    func blockColorSingleAttribute() {
        #expect(markdown(block("а", color: BlockColor(background: .blue))) == "<!-- mynotion:color background=\"blue\" -->\nа\n")
        #expect(markdown(block("а", color: BlockColor(text: .gray))) == "<!-- mynotion:color text=\"gray\" -->\nа\n")
    }

    @Test("Блок без цвета комментария не получает")
    func noCommentWithoutColor() {
        #expect(markdown(block("а")) == "а\n")
    }

    @Test("Цвет на заголовке и пункте списка — комментарий сразу над строкой блока")
    func commentAboveHeadingAndItem() {
        let text = markdown(block(.heading2, "Раздел", color: BlockColor(text: .orange)),
                            block(.bulletItem, "пункт", color: BlockColor(background: .green)))
        #expect(text == "<!-- mynotion:color text=\"orange\" -->\n## Раздел\n\n<!-- mynotion:color background=\"green\" -->\n- пункт\n")
    }

    @Test("Выноска с цветом по умолчанию (серый фон) комментария не получает, а без фона — получает «default»")
    func calloutDefaultsAreImplicit() {
        let plain = markdown(block(.callout, "а", color: BlockColor.defaults(for: .callout)))
        #expect(!plain.contains("mynotion:color"))
        let cleared = markdown(block(.callout, "а", color: .none))
        #expect(cleared.contains("<!-- mynotion:color background=\"default\" -->"))
    }
}
