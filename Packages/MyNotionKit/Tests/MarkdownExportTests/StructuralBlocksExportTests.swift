import Foundation
import Testing
import NotesCore
@testable import MarkdownExport

/// Выгрузка переключателя, цитаты, выноски, разделителя (contracts/markdown-and-notion.md, «Блоки»).
@Suite("Структурные блоки в Markdown")
struct StructuralBlocksExportTests {
    private let pageId = UUID()
    private let writer = MarkdownBlockWriter()

    private func block(_ kind: BlockKind, _ text: String = "", indent: Int = 0, props: BlockProps? = nil,
                       runs: [StyledRun] = []) -> Block {
        Block(pageId: pageId, kind: kind, text: InlineText(text, runs: runs), indent: indent, sortKey: .between(nil, nil),
              color: .defaults(for: kind), props: props ?? .defaults(for: kind))
    }

    private func markdown(_ blocks: Block...) -> String {
        writer.markdown(for: blocks, resolveLink: { _ in nil })
    }

    @Test("Переключатель — <details>/<summary>, дети Markdown между пустыми строками")
    func toggle() {
        let text = markdown(block(.toggle, "Подробнее", runs: [StyledRun(start: 0, length: 9, style: .bold)]),
                            block(.paragraph, "внутри", indent: 1), block(.bulletItem, "пункт", indent: 1),
                            block(.bulletItem, "глубже", indent: 2), block(.paragraph, "после"))
        #expect(text == """
            <details>
            <summary>**Подробнее**</summary>

            внутри

            - пункт
              - глубже

            </details>

            после

            """)
    }

    @Test("Пустой переключатель без детей")
    func emptyToggle() {
        #expect(markdown(block(.toggle, "Р")) == "<details>\n<summary>Р</summary>\n</details>\n")
    }

    @Test("Цитата — «> текст»; дети — строками «> » с их Markdown")
    func quote() {
        let text = markdown(block(.quote, "Мысль\nв две строки"), block(.paragraph, "ребёнок", indent: 1),
                            block(.bulletItem, "пункт", indent: 1), block(.paragraph, "после"))
        #expect(text == """
            > Мысль\u{20}\u{20}
            > в две строки
            >
            > ребёнок
            >
            > - пункт

            после

            """)
    }

    @Test("Выноска — <aside data-icon>, текст и дети Markdown")
    func callout() {
        var props = BlockProps.defaults(for: .callout)
        props.icon = "🚀"
        let text = markdown(block(.callout, "Совет", props: props), block(.paragraph, "подробно", indent: 1))
        #expect(text == """
            <aside data-icon="🚀">

            Совет

            подробно

            </aside>

            """)
        #expect(markdown(block(.callout, "Без иконки", props: .empty)).hasPrefix("<aside data-icon=\"💡\">"))
    }

    @Test("Разделитель — ---")
    func divider() {
        #expect(markdown(block(.paragraph, "до"), block(.divider), block(.paragraph, "после")) == "до\n\n---\n\nпосле\n")
    }

    @Test("Вложенные контейнеры: переключатель внутри выноски")
    func nested() {
        let text = markdown(block(.callout, "Снаружи"), block(.toggle, "Внутри", indent: 1), block(.paragraph, "текст", indent: 2))
        #expect(text == """
            <aside data-icon="💡">

            Снаружи

            <details>
            <summary>Внутри</summary>

            текст

            </details>

            </aside>

            """)
    }
}
