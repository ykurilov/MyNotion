import Foundation
import MarkdownExport
import NotesCore
import Testing
@testable import NotionImport

/// Импорт переключателя, цитаты, выноски, разделителя из Notion и из нашей выгрузки (contracts/markdown-and-notion.md).
@Suite("Структурные блоки из Markdown")
struct StructuralBlocksImportTests {
    private let parser = NotionMarkdownParser()

    private func parse(_ markdown: String) -> ParsedNotionPage {
        parser.parse("# Страница\n\n" + markdown)
    }

    /// Вид, текст и вложенность — то, что видно на странице.
    private func shape(_ blocks: [ParsedBlock]) -> [String] {
        blocks.map { "\($0.indent) \($0.kind.rawValue) \($0.text.string)" }
    }

    @Test("Notion: <details>/<summary> — переключатель с детьми, без «упрощено»")
    func notionToggle() {
        let page = parse("""
            <details>
            <summary>Переключатель</summary>
            Внутри

            - пункт

            </details>

            После
            """)
        #expect(shape(page.blocks) == ["0 toggle Переключатель", "1 paragraph Внутри", "1 bulletItem пункт", "0 paragraph После"])
        #expect(page.simplifications.isEmpty)
    }

    @Test("Notion: вложенные <details>")
    func nestedToggles() {
        let page = parse("<details>\n<summary>А</summary>\n\n<details>\n<summary>Б</summary>\n\nв\n\n</details>\n\n</details>\n")
        #expect(shape(page.blocks) == ["0 toggle А", "1 toggle Б", "2 paragraph в"])
    }

    @Test("Notion: <aside> с эмодзи в начале — выноска с этой иконкой и серым фоном")
    func notionCallout() {
        let page = parse("<aside>\n💡 Выноска с советом\n\n</aside>\n")
        #expect(shape(page.blocks) == ["0 callout Выноска с советом"])
        #expect(page.blocks[0].props.icon == "💡")
        #expect(page.blocks[0].color == BlockColor(background: .gray))
        #expect(page.simplifications.isEmpty)

        let plain = parse("<aside>\nБез значка\n\nвторой абзац\n</aside>\n")
        #expect(shape(plain.blocks) == ["0 callout Без значка", "1 paragraph второй абзац"])
        #expect(plain.blocks[0].props.icon == "💡", "без эмодзи — иконка по умолчанию")
    }

    @Test("«> текст» — цитата; строки подряд — одна цитата с переносом")
    func quote() {
        let page = parse("> Цитата\n> в две строки\n\nпосле\n")
        #expect(shape(page.blocks) == ["0 quote Цитата\nв две строки", "0 paragraph после"])
        #expect(page.simplifications.isEmpty)
    }

    @Test("«---» — разделитель")
    func divider() {
        let page = parse("до\n\n---\n\nпосле\n")
        #expect(shape(page.blocks) == ["0 paragraph до", "0 divider ", "0 paragraph после"])
        #expect(page.simplifications.isEmpty)
    }

    @Test("Выгрузка MyNotion → импорт: те же блоки, вложенность, иконка выноски")
    func roundTrip() {
        let pageId = UUID()
        func block(_ kind: BlockKind, _ text: String = "", indent: Int = 0, icon: String? = nil) -> Block {
            var props = BlockProps.defaults(for: kind)
            if let icon { props.icon = icon }
            return Block(pageId: pageId, kind: kind, text: InlineText(text), indent: indent, sortKey: .between(nil, nil),
                         color: .defaults(for: kind), props: props)
        }
        let blocks = [
            block(.paragraph, "начало"),
            block(.toggle, "Переключатель"), block(.paragraph, "ребёнок", indent: 1), block(.heading2, "Заголовок внутри", indent: 1),
            block(.bulletItem, "пункт", indent: 1), block(.bulletItem, "глубже", indent: 2),
            block(.quote, "Цитата\nс переносом"), block(.paragraph, "в цитате", indent: 1), block(.quote, "вложенная", indent: 1),
            block(.callout, "Выноска", icon: "🚀"), block(.toggle, "переключатель в выноске", indent: 1),
            block(.paragraph, "глубоко", indent: 2),
            block(.divider),
            block(.toggle, "Пустой"),
            block(.paragraph, "конец"),
        ]
        let markdown = MarkdownBlockWriter().markdown(for: blocks, resolveLink: { _ in nil })
        let page = parse(markdown)
        #expect(shape(page.blocks) == shape(blocks.map { ParsedBlock(kind: $0.kind, text: $0.text, indent: $0.indent) }), "\(markdown)")
        #expect(page.blocks.first { $0.kind == .callout }?.props.icon == "🚀")
        #expect(page.simplifications.isEmpty)
    }

    @Test("Импорт из Notion: блоки на странице с вложенностью, иконкой и цветом")
    func importerWritesBlocks() throws {
        let page = parse("<aside>\n🚀 Совет\n\n</aside>\n\n<details>\n<summary>Р</summary>\nвнутри\n\n</details>\n")
        #expect(page.blocks.map(\.kind) == [.callout, .toggle, .paragraph])
        #expect(page.blocks.map(\.indent) == [0, 0, 1])
        #expect(page.blocks[0].props.icon == "🚀")
    }
}
