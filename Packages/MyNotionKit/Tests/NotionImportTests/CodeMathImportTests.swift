import Foundation
import MarkdownExport
import NotesCore
import Testing
@testable import NotionImport

/// Импорт кода, формул и оглавления из Notion и из нашей выгрузки (contracts/markdown-and-notion.md).
@Suite("Код, формулы, оглавление из Markdown")
struct CodeMathImportTests {
    private let parser = NotionMarkdownParser()

    private func parse(_ markdown: String) -> ParsedNotionPage {
        parser.parse("# Страница\n\n" + markdown)
    }

    @Test("Ограда с языком — блок кода с этим языком; текст как есть, без «упрощено»")
    func codeWithLanguage() {
        let page = parse("```python\ndef f():\n    return 1\n\n# конец\n```\n\nпосле\n")
        #expect(page.blocks.map(\.kind) == [.code, .paragraph])
        #expect(page.blocks[0].text.string == "def f():\n    return 1\n\n# конец")
        #expect(page.blocks[0].props.language == "python")
        #expect(page.simplifications.isEmpty)
        #expect(page.unknownCodeLanguages.isEmpty)
    }

    @Test("Имя языка из ограды приводится к нашему id; без имени — простой текст")
    func languageAliases() {
        #expect(parse("```js\nx\n```").blocks.first?.props.language == "javascript")
        #expect(parse("```C++\nx\n```").blocks.first?.props.language == "cpp")
        #expect(parse("```plain text\nx\n```").blocks.first?.props.language == "plain")
        #expect(parse("```\nx\n```").blocks.first?.props.language == "plain")
        #expect(parse("~~~ruby\nputs 1\n~~~").blocks.first?.props.language == "ruby")
    }

    @Test("Незнакомый язык — простой текст и строка в отчёте с его именем")
    func unknownLanguage() {
        let page = parse("```cobol\nDISPLAY 'HI'.\n```\n\n```Fortran\nx\n```\n")
        #expect(page.blocks.map(\.kind) == [.code, .code])
        #expect(page.blocks.allSatisfy { $0.props.language == "plain" })
        #expect(page.blocks[0].text.string == "DISPLAY 'HI'.")
        #expect(page.unknownCodeLanguages == ["cobol", "Fortran"])
        #expect(NotionSimplification.unknownCodeLanguagesTitle(["cobol", "Fortran"])
                == "блоки кода на незнакомых языках (cobol, Fortran) — показаны простым текстом")
    }

    @Test("Ограда из четырёх «`» с тремя внутри")
    func longFence() {
        let page = parse("````markdown\n```js\nx\n```\n````\n")
        #expect(page.blocks.count == 1)
        #expect(page.blocks[0].text.string == "```js\nx\n```")
    }

    @Test("$$ … $$ — формула-блок, в одну строку и в несколько")
    func equationBlock() {
        #expect(parse("$$\nE = mc^2\n$$\n").blocks.map { "\($0.kind) \($0.text.string)" } == ["equation E = mc^2"])
        #expect(parse("$$x^2$$").blocks.map { "\($0.kind) \($0.text.string)" } == ["equation x^2"])
        let multi = parse("$$\na &= b \\\\\nc &= d\n$$\n")
        #expect(multi.blocks.first?.text.string == "a &= b \\\\\nc &= d")
        #expect(multi.simplifications.isEmpty)
    }

    @Test("$…$ в тексте — формула в строке; <span data-equation> — тоже")
    func inlineEquation() {
        let page = parse("Площадь $\\pi r^2$ круга и <span data-equation>a$b&lt;c</span>5\n")
        let text = page.blocks[0].text
        #expect(text.string == "Площадь \u{FFFC} круга и \u{FFFC}5")
        let latex = text.runs.compactMap { run -> String? in if case .equation(let latex) = run.style { latex } else { nil } }
        #expect(latex == ["\\pi r^2", "a$b<c"])
    }

    @Test("Деньги и одиночный $ — обычный текст; \\$ — знак доллара")
    func dollarsAreText() {
        #expect(parse("от $5 до $10\n").blocks[0].text.string == "от $5 до $10")
        #expect(parse("всего $ 5 $ 6\n").blocks[0].text.string == "всего $ 5 $ 6")
        #expect(parse("от \\$5 до \\$10\n").blocks[0].text.string == "от $5 до $10")
        #expect(parse("от $5 до $10\n").blocks[0].text.runs.isEmpty)
    }

    @Test("<nav data-toc></nav> — оглавление")
    func tableOfContents() {
        #expect(parse("<nav data-toc></nav>\n\nтекст\n").blocks.map(\.kind) == [.tableOfContents, .paragraph])
    }

    @Test("Выгрузка → импорт: код, формулы и оглавление те же")
    func roundTrip() {
        let pageId = UUID()
        var props = BlockProps.defaults(for: .code)
        props.language = "markdown"
        let inline = InlineText("цена \u{FFFC}5 и \u{FFFC} и $3 или $4", runs: [StyledRun(start: 5, length: 1, style: .equation("x$")),
                                                                              StyledRun(start: 10, length: 1, style: .equation("\\frac{1}{2}"))])
        let blocks = [
            Block(pageId: pageId, kind: .tableOfContents, sortKey: .between(nil, nil)),
            Block(pageId: pageId, kind: .code, text: InlineText("```\n  отступ\n\nконец"), sortKey: .between(nil, nil), props: props),
            Block(pageId: pageId, kind: .equation, text: InlineText("\\sum_{i=1}^n i"), sortKey: .between(nil, nil)),
            Block(pageId: pageId, kind: .paragraph, text: inline, sortKey: .between(nil, nil)),
        ]
        let markdown = MarkdownBlockWriter().markdown(for: blocks, resolveLink: { _ in nil })
        let page = parse(markdown)
        #expect(page.blocks.map(\.kind) == blocks.map(\.kind))
        #expect(page.blocks.map(\.text) == blocks.map { $0.text.normalized() })
        #expect(page.blocks[1].props.language == "markdown")
    }
}
