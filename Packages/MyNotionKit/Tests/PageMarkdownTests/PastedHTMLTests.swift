import Foundation
import NotesCore
import Testing
@testable import PageMarkdown

/// Вставка ⌘V отрисованного HTML (ответ чата или страница, выделенные мышью) — блоками страницы.
@Suite("Вставка HTML блоками")
struct PastedHTMLTests {
    /// Ответ чата, как его кладёт в буфер Chrome или Electron: `<meta charset>`, стили в каждом теге, обёртки и кнопки.
    static let chatAnswer = """
    <meta charset='utf-8'><div class="message" style="color: rgb(20, 20, 20); font-family: Inter;"><style>.x{color:red}</style>\
    <h2 style="font-size: 20px;">План переноса</h2>
    <p style="margin: 0px;">Сначала <strong>главное</strong>: перенести <em>заметки</em> и проверить <code class="inline">sync</code>. \
    Подробнее — <a href="https://example.com/docs" target="_blank">в документации</a>, старое <del>не нужно</del>.</p>
    <p></p>
    <ul>
      <li>Первый пункт
        <ul><li>Вложенный <b>жирный</b></li><li><p>Второй вложенный</p></li></ul>
      </li>
      <li>Второй пункт</li>
    </ul>
    <ol start="3"><li>Три</li><li>Четыре</li></ol>
    <ul class="contains-task-list"><li class="task-list-item"><input type="checkbox" disabled> Не сделано</li>\
    <li class="task-list-item"><input type="checkbox" checked disabled> Сделано</li></ul>
    <blockquote><p>Цитата из письма</p></blockquote>
    <div class="code-block"><div class="header"><span>swift</span><button>Копировать</button></div>\
    <pre><code class="language-swift">let x = 1
    if x &gt; 0 {
        print("ok")
    }
    </code></pre></div>
    <hr>
    <h4>Итоги</h4>
    <table><thead><tr><th>Имя</th><th>Балл</th></tr></thead><tbody><tr><td>Аня</td><td><strong>5</strong></td></tr>\
    <tr><td>Боря</td><td>4</td></tr></tbody></table>
    <p>Конец <span style="font-weight: 600;">ответа</span>.</p><script>alert(1)</script><svg><path d="M0"/></svg></div>
    """

    private func blocks(_ html: String, text: String = "") -> [Block]? {
        PastedText.blocks(from: text, html: html, pageId: UUID(), hasRichText: true)
    }

    @Test("Ответ чата: заголовки, вложенный список, нумерованный, задачи, цитата, код с языком, разделитель, таблица")
    func chatAnswerBlocks() throws {
        let blocks = try #require(blocks(Self.chatAnswer))
        let flow = blocks.filter { $0.containerId == nil }
        #expect(flow.map(\.kind) == [.heading2, .paragraph, .bulletItem, .bulletItem, .bulletItem, .bulletItem, .numberedItem, .numberedItem,
                                     .checkbox, .checkbox, .quote, .code, .divider, .heading3, .table, .paragraph])
        #expect(flow.map(\.text.string) == ["План переноса", "Сначала главное: перенести заметки и проверить sync. Подробнее — в документации, старое не нужно.",
                                            "Первый пункт", "Вложенный жирный", "Второй вложенный", "Второй пункт", "Три", "Четыре",
                                            "Не сделано", "Сделано", "Цитата из письма", "let x = 1\nif x > 0 {\n    print(\"ok\")\n}", "",
                                            "Итоги", "", "Конец ответа."])
        #expect(flow.map(\.indent) == [0, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        #expect(flow.map(\.isChecked) == [false, false, false, false, false, false, false, false, false, true, false, false, false, false, false, false])
        #expect(flow[11].props.language == "swift")
        let cells = blocks.filter { $0.kind == .tableCell }
        #expect(cells.map(\.text.string) == ["Имя", "Балл", "Аня", "5", "Боря", "4"])
        #expect(cells[3].text.runs.map(\.style) == [.bold])
    }

    @Test("Оформление в строке: жирный, курсив, код, зачёркнутый, ссылка; жирный из style")
    func inlineFormatting() throws {
        let flow = try #require(blocks(Self.chatAnswer)).filter { $0.containerId == nil }
        #expect(flow[1].text.runs.map(\.style) == [.bold, .italic, .code, .link(URL(string: "https://example.com/docs")!), .strikethrough])
        #expect(flow[3].text.runs == [StyledRun(start: 10, length: 6, style: .bold)])
        #expect(flow[15].text.runs.map(\.style) == [.bold])
    }

    @Test("Знаки текста страницы — текст: звёздочки, решётка, подчёркивания и «1.» в начале не становятся оформлением")
    func literalMarkdownCharacters() throws {
        let html = "<h3>Файл *.md</h3><p># не заголовок, 2 * 3 * 4, snake_case_name, [x](y)</p><p>1. не список</p>"
        let flow = try #require(blocks(html))
        #expect(flow.map(\.kind) == [.heading3, .paragraph, .paragraph])
        #expect(flow.map(\.text.string) == ["Файл *.md", "# не заголовок, 2 * 3 * 4, snake_case_name, [x](y)", "1. не список"])
        #expect(flow.allSatisfy { $0.text.runs.isEmpty })
    }

    @Test("Перевод строки <br> — строка внутри абзаца; &nbsp; и сущности раскрыты")
    func lineBreaksAndEntities() throws {
        let flow = try #require(blocks("<h2>Адрес</h2><p>Москва,&nbsp;ул.&nbsp;Ленина<br>дом&nbsp;1 &laquo;А&raquo; &amp; &#8470;2</p>"))
        #expect(flow.map(\.kind) == [.heading2, .paragraph])
        #expect(flow[1].text.string == "Москва, ул. Ленина\nдом 1 «А» & №2")
    }

    @Test("Google Docs: обёртка <b style=\"font-weight:normal\"> — не жирный, <span style=\"font-weight:700\"> — жирный")
    func googleDocsWeights() throws {
        let html = """
        <meta charset="utf-8"><b style="font-weight:normal;" id="docs-internal-guid-1"><h1 dir="ltr"><span style="font-size:20pt;">Отчёт</span></h1>\
        <p dir="ltr"><span style="font-weight:400;">Обычный и </span><span style="font-weight:700;">жирный</span></p></b>
        """
        let flow = try #require(blocks(html))
        #expect(flow.map(\.kind) == [.heading1, .paragraph])
        #expect(flow[1].text.runs == [StyledRun(start: 10, length: 6, style: .bold)])
    }

    @Test("Абзацы без строения (Word, Pages, Заметки) — не блоки из HTML: их вставит прежняя вставка с оформлением")
    func paragraphsOnly() {
        let word = """
        <html xmlns:o="urn:schemas-microsoft-com:office:office"><head><style>p.MsoNormal{margin:0}</style></head><body lang=RU>\
        <div class=WordSection1><p class=MsoNormal><b>Важно:</b> один абзац текста<o:p></o:p></p></div></body></html>
        """
        #expect(blocks(word, text: "Важно: один абзац текста") == nil)
        #expect(blocks("<p>Первый абзац</p><p>Второй <i>абзац</i></p>", text: "Первый абзац\nВторой абзац") == nil)
    }

    @Test("Один блок — как раньше, в строку: заголовок, пункт или код одни")
    func singleBlock() {
        #expect(blocks("<h2>Только заголовок</h2>", text: "Только заголовок") == nil)
        #expect(blocks("<ul><li>один пункт</li></ul>", text: "один пункт") == nil)
        #expect(blocks("<pre>let x = 1\nlet y = 2</pre>", text: "let x = 1\nlet y = 2") == nil)
    }

    @Test("HTML-обёртка Markdown (редактор кода) уступает Markdown простого текста")
    func markdownInsideWrapper() throws {
        let text = "## План\n\n- **первый**\n- второй"
        let html = """
        <meta charset='utf-8'><div style="color: #d4d4d4;font-family: Menlo;white-space: pre;"><div><span style="color: #569cd6;">## План</span></div>\
        <br><div><span>- </span><span style="font-weight: bold;">**первый**</span></div><div><span>- второй</span></div></div>
        """
        let flow = try #require(blocks(html, text: text))
        #expect(flow.map(\.kind) == [.heading2, .bulletItem, .bulletItem])
        #expect(flow.map(\.text.string) == ["План", "первый", "второй"])
        #expect(flow[1].text.runs.map(\.style) == [.bold])
    }

    @Test("Пустые абзацы, стили, скрипты и кнопки отброшены; заголовки глубже третьего — третьего уровня")
    func junkDropped() throws {
        let html = """
        <html><head><title>Стр</title><style>h1{}</style></head><body><div><div><p>&nbsp;</p><h1>Один</h1><p> </p>\
        <button>Поделиться</button><h6>Шесть</h6><div><span></span></div><noscript>вкл JS</noscript></div></div></body></html>
        """
        let flow = try #require(blocks(html))
        #expect(flow.map(\.kind) == [.heading1, .heading3])
        #expect(flow.map(\.text.string) == ["Один", "Шесть"])
    }

    @Test("Незакрытые <li> и <p> закрываются следующими, как в браузере")
    func unclosedTags() throws {
        let flow = try #require(blocks("<ul><li>раз<li>два</ul><p>абзац<p>ещё"))
        #expect(flow.map(\.kind) == [.bulletItem, .bulletItem, .paragraph, .paragraph])
        #expect(flow.map(\.text.string) == ["раз", "два", "абзац", "ещё"])
    }

    // MARK: Настоящий буфер

    /// Снято на iMac: страница с отрисованным ответом, «Выделить всё», ⌘C — `public.html` и простой текст буфера.
    private func fixture(_ name: String) throws -> (html: String, text: String) {
        let folder = PageMarkdownFixture.fixtures.appendingPathComponent("Paste", isDirectory: true)
        return (try String(contentsOf: folder.appendingPathComponent(name + ".html"), encoding: .utf8),
                try String(contentsOf: folder.appendingPathComponent(name + ".txt"), encoding: .utf8))
    }

    @Test("Ответ из Safari и Chrome: те же блоки, подпись языка над кодом и пробелы Safari не мешают", arguments: ["safari-chat", "chrome-chat"])
    func realChatAnswer(_ name: String) throws {
        let sample = try fixture(name)
        let blocks = try #require(blocks(sample.html, text: sample.text))
        let flow = blocks.filter { $0.containerId == nil }
        #expect(flow.map(\.kind) == [.heading2, .paragraph, .bulletItem, .bulletItem, .bulletItem, .bulletItem, .numberedItem, .numberedItem,
                                     .checkbox, .checkbox, .quote, .code, .divider, .heading3, .table, .paragraph])
        #expect(flow.map(\.text.string) == ["План переноса", "Сначала главное: перенести заметки и проверить sync. Подробнее — в документации, старое не нужно.",
                                            "Первый пункт", "Вложенный жирный", "Второй вложенный", "Второй пункт", "Раз", "Два",
                                            "Не сделано", "Сделано", "Цитата из письма", "let x = 1\nif x > 0 {\n    print(\"ok\")\n}", "",
                                            "Итоги", "", "Конец ответа."])
        #expect(flow.map(\.indent) == [0, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        #expect(flow[9].isChecked && !flow[8].isChecked)
        #expect(flow[11].props.language == "swift")
        #expect(flow[1].text.runs.map(\.style) == [.bold, .italic, .code, .link(URL(string: "https://example.com/docs")!), .strikethrough])
        #expect(blocks.filter { $0.kind == .tableCell }.map(\.text.string) == ["Имя", "Балл", "Аня", "5", "Боря", "4"])
    }

    @Test("Вся страница README на GitHub из Chrome: README — заголовками и абзацами со ссылками, меню и кнопки сайта не ломают разбор")
    func realGitHubPage() throws {
        let sample = try fixture("chrome-github")
        let flow = try #require(blocks(sample.html, text: sample.text)).filter { $0.containerId == nil }
        let headings = flow.filter { [.heading1, .heading2, .heading3].contains($0.kind) }.map(\.text.string)
        #expect(headings.contains("Markdown Test File"))
        #expect(headings.firstIndex(of: "Inspiration").map { headings.firstIndex(of: "Markdown Test File")! < $0 } == true)
        #expect(headings.contains("License"))
        let inspiration = try #require(flow.first { $0.text.string.hasPrefix("The file is based on") })
        #expect(inspiration.kind == .paragraph)
        #expect(inspiration.text.runs.contains { if case .link = $0.style { true } else { false } })
        #expect(!flow.contains { $0.text.string.isEmpty && $0.kind == .paragraph })
    }
}
