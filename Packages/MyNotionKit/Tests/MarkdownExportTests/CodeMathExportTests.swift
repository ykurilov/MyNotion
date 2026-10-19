import Foundation
import Testing
import NotesCore
@testable import MarkdownExport

/// Выгрузка кода, формул и оглавления (contracts/markdown-and-notion.md, «Блоки» и «В строке»).
@Suite("Код, формулы, оглавление в Markdown")
struct CodeMathExportTests {
    private let pageId = UUID()
    private let writer = MarkdownBlockWriter()

    private func block(_ kind: BlockKind, _ text: String = "", language: String? = nil, runs: [StyledRun] = []) -> Block {
        var props = BlockProps.defaults(for: kind)
        if let language { props.language = language }
        return Block(pageId: pageId, kind: kind, text: InlineText(text, runs: runs), sortKey: .between(nil, nil), props: props)
    }

    private func markdown(_ blocks: Block...) -> String {
        writer.markdown(for: blocks, resolveLink: { _ in nil })
    }

    @Test("Код — ограда с языком; строки и отступы как есть")
    func codeWithLanguage() {
        let code = "func go() {\n    return 1\n\n}"
        #expect(markdown(block(.code, code, language: "swift"), block(.paragraph, "после")) == """
            ```swift
            func go() {
                return 1

            }
            ```

            после

            """)
    }

    @Test("Простой текст — ограда без названия; пустой код — пустая ограда")
    func plainCode() {
        #expect(markdown(block(.code, "a * b _c_", language: "plain")) == "```\na * b _c_\n```\n")
        #expect(markdown(block(.code, "", language: "plain")) == "```\n```\n")
    }

    @Test("Три «`» внутри кода — ограда из четырёх")
    func fenceInsideCode() {
        #expect(markdown(block(.code, "```js\nx\n```", language: "markdown")) == "````markdown\n```js\nx\n```\n````\n")
    }

    @Test("Формула-блок — $$, запись, $$")
    func equationBlock() {
        #expect(markdown(block(.equation, "E = mc^2")) == "$$\nE = mc^2\n$$\n")
        #expect(markdown(block(.equation, "a &= b \\\\\nc &= d")) == "$$\na &= b \\\\\nc &= d\n$$\n")
    }

    @Test("Оглавление — <nav data-toc></nav>")
    func tableOfContents() {
        #expect(markdown(block(.tableOfContents)) == "<nav data-toc></nav>\n")
    }

    @Test("Формула в строке — $запись$; рядом цифра или $ в записи — <span data-equation>")
    func inlineEquation() {
        func paragraph(_ text: String, latex: String) -> Block {
            let at = (text as NSString).range(of: "\u{FFFC}").location
            return block(.paragraph, text, runs: [StyledRun(start: at, length: 1, style: .equation(latex))])
        }
        #expect(markdown(paragraph("Площадь \u{FFFC} круга", latex: "\\pi r^2")) == "Площадь $\\pi r^2$ круга\n")
        #expect(markdown(paragraph("цена \u{FFFC}5", latex: "x")) == "цена <span data-equation>x</span>5\n")
        #expect(markdown(paragraph("\u{FFFC}", latex: "a$b<c&d")) == "<span data-equation>a$b&lt;c&amp;d</span>\n")
    }

    @Test("Два знака $ в обычном тексте экранируются: импорт не примет их за формулу")
    func dollarsInText() {
        #expect(markdown(block(.paragraph, "от $5 до $10")) == "от \\$5 до \\$10\n")
        #expect(markdown(block(.paragraph, "всего $5")) == "всего $5\n")
    }
}
