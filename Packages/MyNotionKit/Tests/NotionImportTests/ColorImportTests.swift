import Foundation
import MarkdownExport
import NotesCore
import Testing
@testable import NotionImport

/// Возврат цветов из нашей выгрузки (FR-112, SC-105; contracts/markdown-and-notion.md). Цвета из «Markdown & CSV» Notion
/// не приходят (research R14), поэтому разбирается только собственный формат.
@Suite("Импорт цветов из своей выгрузки")
struct ColorImportTests {
    private let parser = NotionMarkdownParser()

    private func blocks(_ markdown: String) -> [ParsedBlock] { parser.parse("# Страница\n\n" + markdown).blocks }

    private func run(_ start: Int, _ length: Int, _ style: InlineStyle) -> StyledRun {
        StyledRun(start: start, length: length, style: style)
    }

    @Test("<span data-color> — цвет текста")
    func textColor() {
        let text = blocks("Это <span data-color=\"red\">слово</span> тут\n")[0].text
        #expect(text == InlineText("Это слово тут", runs: [run(4, 5, .textColor(.red))]))
    }

    @Test("<mark data-color> — цвет фона")
    func backgroundColor() {
        let text = blocks("<mark data-color=\"yellow\">слово</mark>\n")[0].text
        #expect(text == InlineText("слово", runs: [run(0, 5, .backgroundColor(.yellow))]))
    }

    @Test("Вложенные mark и span — оба цвета на одном тексте")
    func bothColors() {
        let text = blocks("<mark data-color=\"yellow\"><span data-color=\"red\">слово</span></mark>\n")[0].text
        #expect(text == InlineText("слово", runs: [run(0, 5, .textColor(.red)), run(0, 5, .backgroundColor(.yellow))]).normalized())
    }

    @Test("Цвет вместе с жирным и ссылкой")
    func colorWithEmphasis() {
        let text = blocks("<span data-color=\"blue\">**а** б</span>\n")[0].text
        #expect(text == InlineText("а б", runs: [run(0, 3, .textColor(.blue)), run(0, 1, .bold)]).normalized())
    }

    @Test("Вложенный цвет перекрывает внешний на своём участке")
    func innerColorWins() {
        let text = blocks("<span data-color=\"red\">а<span data-color=\"green\">б</span>в</span>\n")[0].text
        #expect(text == InlineText("абв", runs: [run(0, 1, .textColor(.red)), run(1, 1, .textColor(.green)), run(2, 1, .textColor(.red))]))
    }

    @Test("Неизвестное имя цвета и чужие span: теги убираются, текст остаётся")
    func unknownColorIsIgnored() {
        #expect(blocks("<span data-color=\"magenta\">слово</span>\n")[0].text == InlineText("слово"))
        #expect(blocks("<span class=\"x\">слово</span>\n")[0].text == InlineText("слово"))
    }

    @Test("Неоткрытый или незакрытый тег не ломает остальной текст")
    func unbalancedTags() {
        #expect(blocks("слово</span> ещё\n")[0].text == InlineText("слово ещё"))
        #expect(blocks("<span data-color=\"red\">слово\n")[0].text == InlineText("слово", runs: [run(0, 5, .textColor(.red))]))
    }

    // MARK: Цвет блока

    @Test("Комментарий mynotion:color красит следующий блок")
    func blockColor() {
        let parsed = blocks("<!-- mynotion:color text=\"red\" background=\"yellow\" -->\nВажное\n\nОбычный\n")
        #expect(parsed.map(\.color) == [BlockColor(text: .red, background: .yellow), .none])
        #expect(parsed.map(\.text.string) == ["Важное", "Обычный"])
    }

    @Test("Цвет заголовка и пункта списка")
    func headingAndItem() {
        let parsed = blocks("<!-- mynotion:color text=\"orange\" -->\n## Раздел\n\n<!-- mynotion:color background=\"green\" -->\n- пункт\n")
        #expect(parsed.map(\.kind) == [.heading2, .bulletItem])
        #expect(parsed.map(\.color) == [BlockColor(text: .orange), BlockColor(background: .green)])
    }

    @Test("Комментарий не становится абзацем, и пустых абзацев из-за него нет")
    func commentIsNotABlock() {
        #expect(blocks("<!-- mynotion:color text=\"gray\" -->\nа\n").count == 1)
    }

    @Test("Неизвестные цвета в комментарии отбрасываются")
    func unknownValues() {
        #expect(blocks("<!-- mynotion:color text=\"magenta\" -->\nа\n")[0].color == .none)
    }

    @Test("«default» сбрасывает цвет выноски; без атрибута у выноски остаётся серый фон")
    func calloutDefaults() {
        #expect(NotionColorComment.parse("<!-- mynotion:color background=\"default\" -->")?.resolved(for: .callout) == BlockColor.none)
        #expect(NotionColorComment.parse("<!-- mynotion:color text=\"red\" -->")?.resolved(for: .callout)
                == BlockColor(text: .red, background: .gray))
        #expect(NotionColorComment.parse("<!-- mynotion:color text=\"red\" -->")?.resolved(for: .paragraph) == BlockColor(text: .red))
    }

    // MARK: Круг «выгрузка → импорт»

    @Test("Выгрузка и возврат дают тот же текст, те же цвета и тот же цвет блока")
    func roundTrip() {
        let pageId = UUID()
        func make(_ kind: BlockKind, _ text: String, runs: [StyledRun] = [], color: BlockColor = .none) -> Block {
            Block(pageId: pageId, kind: kind, text: InlineText(text, runs: runs), sortKey: .between(nil, nil), color: color)
        }
        let source = [
            make(.paragraph, "Красный и жёлтый фон", runs: [run(0, 7, .textColor(.red)), run(10, 10, .backgroundColor(.yellow))]),
            make(.heading1, "Заголовок", color: BlockColor(text: .blue)),
            make(.bulletItem, "пункт *со знаками*", runs: [run(0, 5, .bold), run(0, 5, .textColor(.green))],
                 color: BlockColor(background: .gray)),
            make(.paragraph, "Всё сразу", runs: [run(0, 9, .textColor(.purple)), run(0, 9, .backgroundColor(.pink)), run(0, 3, .italic)],
                 color: BlockColor(text: .brown, background: .orange)),
        ]
        let markdown = MarkdownBlockWriter().markdown(for: source, resolveLink: { _ in nil })
        let parsed = parser.parse("# Страница\n\n" + markdown).blocks
        #expect(parsed.map(\.kind) == source.map(\.kind))
        #expect(parsed.map(\.color) == source.map(\.color))
        #expect(parsed.map(\.text) == source.map { $0.text.normalized() })
    }
}
