import Foundation
import MarkdownExport
import NotesCore
import Testing
@testable import NotionImport

/// Разбор Markdown из Notion и из нашей выгрузки в блоки (T084, contracts/files-import-export.md, research R11).
@Suite("Разбор Markdown Notion")
struct NotionMarkdownParserTests {
    private let parser = NotionMarkdownParser()

    private func blocks(_ markdown: String) -> [ParsedBlock] {
        parser.parse("# Страница\n\n" + markdown).blocks
    }

    private func block(_ kind: BlockKind, _ text: String, indent: Int = 0, checked: Bool = false) -> ParsedBlock {
        ParsedBlock(kind: kind, text: InlineText(text), indent: indent, isChecked: checked)
    }

    private func styled(_ string: String, _ runs: [(Int, Int, InlineStyle)]) -> InlineText {
        InlineText(string, runs: runs.map { StyledRun(start: $0.0, length: $0.1, style: $0.2) }).normalized()
    }

    // MARK: Название и иконка

    @Test("Первая строка `# Название` — название страницы, эмодзи перед ним — иконка")
    func titleAndIcon() {
        let page = parser.parse("# 📘 Проекты\n\nТекст\n")
        #expect(page.title == "Проекты")
        #expect(page.icon == "📘")
        #expect(page.blocks == [block(.paragraph, "Текст")])

        let plain = parser.parse("# MyNotion — сравнение\n")
        #expect(plain.title == "MyNotion — сравнение")
        #expect(plain.icon == nil)
        #expect(plain.blocks.isEmpty)
    }

    @Test("Без строки названия название пустое, а `#` дальше по тексту — заголовок")
    func noTitleLine() {
        let page = parser.parse("Текст\n\n# Заголовок\n")
        #expect(page.title == nil)
        #expect(page.blocks == [block(.paragraph, "Текст"), block(.heading1, "Заголовок")])
    }

    // MARK: Поддерживаемые блоки (таблица contracts/files-import-export.md)

    @Test("Абзацы и заголовки трёх уровней; глубже — третий уровень")
    func paragraphsAndHeadings() {
        #expect(blocks("Абзац\n\n# Один\n\n## Два\n\n### Три\n\n#### Четыре\n") == [
            block(.paragraph, "Абзац"), block(.heading1, "Один"), block(.heading2, "Два"),
            block(.heading3, "Три"), block(.heading3, "Четыре"),
        ])
    }

    @Test("Списки: маркер, номер, чекбоксы; два пробела после `[ ]` у Notion не попадают в текст")
    func lists() {
        #expect(blocks("- а\n* б\n+ в\n1. один\n2) два\n- [ ]  дело\n- [x] готово\n- [X] тоже\n") == [
            block(.bulletItem, "а"), block(.bulletItem, "б"), block(.bulletItem, "в"),
            block(.numberedItem, "один"), block(.numberedItem, "два"),
            block(.checkbox, "дело"), block(.checkbox, "готово", checked: true), block(.checkbox, "тоже", checked: true),
        ])
    }

    @Test("Вложенность списков: у Notion — по 4 пробела, у нашей выгрузки — по ширине маркера")
    func listNesting() {
        let notion = "- а\n    - б\n        - в\n- г\n1. один\n    1. вложенный\n- [ ]  дело\n    - [ ]  вложенное\n"
        #expect(blocks(notion).map(\.indent) == [0, 1, 2, 0, 0, 1, 0, 1])
        let ours = "1. а\n   - б\n     1. в\n10. г\n    - д\n- [ ] е\n  - ж\n"
        #expect(blocks(ours).map(\.indent) == [0, 1, 2, 0, 1, 0, 1])
    }

    @Test("Отступ не глубже 8")
    func indentLimit() {
        let deep = (0..<11).map { String(repeating: "    ", count: $0) + "- \($0)" }.joined(separator: "\n")
        #expect(blocks(deep).map(\.indent) == [0, 1, 2, 3, 4, 5, 6, 7, 8, 8, 8])
    }

    @Test("Строки блока подряд — один блок с переносами; два пробела в конце строки не попадают в текст")
    func lineBreaksInsideBlock() {
        #expect(blocks("Первая строка\nВторая\nТретья\n") == [block(.paragraph, "Первая строка\nВторая\nТретья")])
        #expect(blocks("раз  \nдва\n") == [block(.paragraph, "раз\nдва")])
        #expect(blocks("- пункт  \n  продолжение\n- второй\n") == [block(.bulletItem, "пункт\nпродолжение"), block(.bulletItem, "второй")])
    }

    @Test("Лишняя пустая строка между блоками — пустой абзац; в начале и в конце — нет")
    func emptyParagraphs() {
        #expect(blocks("\n\nа\n\n\nб\n\n\n\n- в\n\n\n- г\n\n\n") == [
            block(.paragraph, "а"), block(.paragraph, ""), block(.paragraph, "б"), block(.paragraph, ""), block(.paragraph, ""),
            block(.bulletItem, "в"), block(.paragraph, ""), block(.bulletItem, "г"),
        ])
    }

    @Test("Оформление в строке: жирный, курсив, зачёркнутый, код, подчёркнутый, ссылка")
    func inlineStyles() {
        let text = blocks("**ж** *к* ~~з~~ `код` <u>п</u> [с](https://example.com)\n")[0].text
        #expect(text == styled("ж к з код п с", [
            (0, 1, .bold), (2, 1, .italic), (4, 1, .strikethrough), (6, 3, .code), (10, 1, .underline),
            (12, 1, .link(URL(string: "https://example.com")!)),
        ]))
    }

    @Test("Подчёркивания и теги тоже оформление: __ж__, _к_, <strong>, <em>, <del>, <b>, <i>, <s>")
    func alternativeStyleSyntax() {
        let text = blocks("__а__ _б_ <strong>в</strong> <em>г</em> <del>д</del> <b>е</b> <i>ё</i> <s>ж</s>\n")[0].text
        #expect(text == styled("а б в г д е ё ж", [
            (0, 1, .bold), (2, 1, .italic), (4, 1, .bold), (6, 1, .italic), (8, 1, .strikethrough),
            (10, 1, .bold), (12, 1, .italic), (14, 1, .strikethrough),
        ]))
    }

    @Test("Вложенное оформление: ***жк***, **ж *жк* ж**, [**ссылка**](url)")
    func nestedStyles() {
        #expect(blocks("***а***\n")[0].text == styled("а", [(0, 1, .bold), (0, 1, .italic)]))
        #expect(blocks("**а *б* в**\n")[0].text == styled("а б в", [(0, 5, .bold), (2, 1, .italic)]))
        let url = URL(string: "https://example.com/a?b=1")!
        #expect(blocks("[**а** б](https://example.com/a?b=1)\n")[0].text == styled("а б", [(0, 1, .bold), (0, 3, .link(url))]))
    }

    @Test("Экранированные знаки и знаки, которые не открывают оформление, остаются текстом")
    func literalCharacters() {
        #expect(blocks("\\*не жирный\\* a*b 2 * 3 snake_case_name \\[x\\] \\# \\!\n")[0].text
                == InlineText("*не жирный* a*b 2 * 3 snake_case_name [x] # !"))
        #expect(blocks("``код с ` внутри``\n")[0].text == styled("код с ` внутри", [(0, 14, .code)]))
        #expect(blocks("`**не жирный**`\n")[0].text == styled("**не жирный**", [(0, 13, .code)]))
        #expect(blocks("&amp; &lt;b&gt; &#169; &#x41;\n")[0].text == InlineText("& <b> © A"))
    }

    @Test("Адрес в угловых скобках — ссылка; незнакомые теги убираются, <br> — перенос")
    func autolinksAndTags() {
        let url = URL(string: "https://notion.so")!
        #expect(blocks("<https://notion.so>\n")[0].text == styled("https://notion.so", [(0, 17, .link(url))]))
        #expect(blocks("<span style=\"color:red\">красный</span> текст<br>дальше\n")[0].text == InlineText("красный текст\nдальше"))
    }

    // MARK: Ссылки на страницы

    @Test("Строка из одной ссылки на файл страницы — блок pageLink с раскодированным путём")
    func pageLinks() {
        let parsed = blocks("[Подстраница](MyNotion%20%E2%80%94%20%D1%81/%D0%9F%D0%BE%D0%B4%20c250de6dd9df457f918f9bfe5aba4bbd.md)\n\n[База](%D0%91%D0%B0%D0%B7%D0%B0%204c5d6e7f8091a2b3c4d5e6f708192a34.csv)\n")
        #expect(parsed == [
            ParsedBlock(kind: .pageLink, text: InlineText("Подстраница"), pagePath: "MyNotion — с/Под c250de6dd9df457f918f9bfe5aba4bbd.md"),
            ParsedBlock(kind: .pageLink, text: InlineText("База"), pagePath: "База 4c5d6e7f8091a2b3c4d5e6f708192a34.csv"),
        ])
    }

    @Test("Ссылка на страницу внутри текста — упоминание (002); строка из одной ссылки на адрес — абзац с пометкой адреса")
    func pageLinksInText() throws {
        let mentioned = try #require(blocks("См. [Дневник](%D0%94%D0%BD%D0%B5%D0%B2%D0%BD%D0%B8%D0%BA.md) тут\n").first)
        let mention = try #require(mentioned.mentions.first)
        #expect(mentioned.kind == .paragraph)
        #expect(mentioned.text == InlineText("См. \u{FFFC} тут", runs: [StyledRun(start: 4, length: 1, style: .mention(mention.placeholder))]))
        #expect(mention.path == "Дневник.md" && mention.title == "Дневник")
        let url = URL(string: "https://www.notion.so/MyNotion-2a3b4c5d6e7f8091a2b3c4d5e6f70812?pvs=21")!
        #expect(blocks("[MyNotion](https://www.notion.so/MyNotion-2a3b4c5d6e7f8091a2b3c4d5e6f70812?pvs=21)\n") == [
            ParsedBlock(kind: .paragraph, text: styled("MyNotion", [(0, 8, .link(url))]), standaloneURL: url),
        ])
    }

    // MARK: Упрощение до текста (FR-026)

    @Test("Вложение внутри текста — «[файл: имя]»; картинка на своей строке — блок-картинка (002, contracts/markdown-and-notion.md)")
    func files() {
        let page = parser.parse("# С\n\n![schema.png](%D0%98%D0%B4%D0%B5%D0%B8/schema.png)\n\nОтчёт: [отчёт.pdf](%D0%9F/%D0%BE%D1%82%D1%87%D1%91%D1%82.pdf)\n")
        // Подпись, равная имени файла, — так Notion пишет картинку без подписи.
        var image = block(.image, "")
        image.attachmentPath = "Идеи/schema.png"
        #expect(page.blocks == [image, block(.paragraph, "Отчёт: [файл: отчёт.pdf]")])
        #expect(page.simplifications == [.file: 1])
    }

    @Test("Встраивание — абзац с исходным текстом; цитата, выноска, переключатель, разделитель (US1), код и формула (US4) — блоками")
    func simplifiedBlocks() {
        let markdown = """
            # С

            > Цитата
            > в две строки

            <aside>
            💡 Выноска

            </aside>

            ```swift
            let a = **1**
              print(a)
            ```

            <details>
            <summary>Переключатель</summary>
            Внутри

            </details>

            ---

            $$
            E = mc^2
            $$

            <iframe src="https://www.youtube.com/embed/xyz"></iframe>

            <figure><img src="x.png">Подпись</figure>
            """
        let page = parser.parse(markdown)
        var callout = ParsedBlock(kind: .callout, text: InlineText("Выноска"), color: .defaults(for: .callout), props: .defaults(for: .callout))
        callout.props.icon = "💡"
        var code = ParsedBlock(kind: .code, text: InlineText("let a = **1**\n  print(a)"), props: .defaults(for: .code))
        code.props.language = "swift"
        #expect(page.blocks == [
            block(.quote, "Цитата\nв две строки"),
            callout,
            code,
            block(.toggle, "Переключатель"),
            block(.paragraph, "Внутри", indent: 1),
            block(.divider, ""),
            block(.equation, "E = mc^2"),
            block(.paragraph, "https://www.youtube.com/embed/xyz"),
            block(.paragraph, "Подпись"),
        ])
        #expect(page.simplifications == [.embed: 2])
    }

    @Test("Таблица Markdown — блок-таблица (002, US6), а не абзацы; подробности — TablesImportTests")
    func markdownTable() {
        let page = parser.parse("# С\n\n| Имя | Роль |\n| --- | :-: |\n| Юрий | автор |\n")
        #expect(page.blocks.map(\.kind) == [.table])
        #expect(page.simplifications.isEmpty)
    }

    @Test("Строка с | без строки-разделителя — обычный абзац")
    func pipeWithoutTable() {
        #expect(blocks("| не таблица |\n") == [block(.paragraph, "| не таблица |")])
    }

    // MARK: Живая выгрузка Notion 7.38.1

    @Test("Страница «MyNotion — сравнение» из настоящего Notion")
    func liveNotionPage() {
        let markdown = """
            # MyNotion — сравнение

            Обычный абзац текста. Здесь есть **жирный**, *курсив*, ~~зачёркнутый~~, `код в строке` и [ссылка](https://www.notion.so).

            # Заголовок первого уровня

            - Первый пункт маркированного списка
            - Второй пункт
                - Вложенный пункт
                    - Ещё глубже
            1. Первый пункт нумерованного списка
                1. Вложенный нумерованный
            - [ ]  Невыполненная задача
            - [x]  Выполненная задача
                - [ ]  Вложенная задача

            Первая строка блока
            Вторая строка после переноса
            """
        let page = parser.parse(markdown)
        #expect(page.title == "MyNotion — сравнение")
        #expect(page.blocks.map(\.kind) == [.paragraph, .heading1, .bulletItem, .bulletItem, .bulletItem, .bulletItem,
                                            .numberedItem, .numberedItem, .checkbox, .checkbox, .checkbox, .paragraph])
        #expect(page.blocks.map(\.indent) == [0, 0, 0, 0, 1, 2, 0, 1, 0, 0, 1, 0])
        #expect(page.blocks[9].isChecked)
        #expect(page.blocks[8].text == InlineText("Невыполненная задача"))
        #expect(page.blocks[11].text == InlineText("Первая строка блока\nВторая строка после переноса"))
        let first = page.blocks[0].text
        #expect(first.string == "Обычный абзац текста. Здесь есть жирный, курсив, зачёркнутый, код в строке и ссылка.")
        #expect(first.runs.map(\.style) == [.bold, .italic, .strikethrough, .code, .link(URL(string: "https://www.notion.so")!)])
        #expect(page.simplifications.isEmpty)
    }

    // MARK: Круговой тест: наша выгрузка → разбор → те же блоки

    private let writer = MarkdownBlockWriter()

    /// Блок записи → то, что должен вернуть разбор его Markdown.
    private func expectedParse(of block: Block, linkTitles: [UUID: (String, String?)]) -> ParsedBlock {
        switch block.kind {
        case .pageLink:
            let (title, path) = linkTitles[block.linkedPageId!]!
            // Страница в корзине — в выгрузке только её название.
            guard let path else { return ParsedBlock(kind: .paragraph, text: InlineText(title)) }
            return ParsedBlock(kind: .pageLink, text: InlineText(title), pagePath: path)
        case .heading1, .heading2, .heading3:
            return ParsedBlock(kind: block.kind, text: InlineText(block.text.string.replacingOccurrences(of: "\n", with: " "),
                                                                  runs: block.text.runs).normalized())
        default:
            let isList = block.kind == .bulletItem || block.kind == .numberedItem || block.kind == .checkbox
            return ParsedBlock(kind: block.kind, text: block.text.normalized(), indent: isList ? block.indent : 0, isChecked: block.isChecked)
        }
    }

    private func roundTrip(_ blocks: [Block], linkTitles: [UUID: (String, String?)] = [:],
                           sourceLocation: SourceLocation = #_sourceLocation) {
        let markdown = "# Страница\n\n" + writer.markdown(for: blocks) { id in
            linkTitles[id].map { PageLinkTarget(title: $0.0, path: $0.1) }
        }
        var expected = blocks.map { expectedParse(of: $0, linkTitles: linkTitles) }
        // Пустые абзацы в начале и в конце страницы выгрузка не пишет.
        while expected.first.map({ $0.kind == .paragraph && $0.text.string.isEmpty }) == true { expected.removeFirst() }
        while expected.last.map({ $0.kind == .paragraph && $0.text.string.isEmpty }) == true { expected.removeLast() }
        let parsed = parser.parse(markdown)
        #expect(parsed.title == "Страница", sourceLocation: sourceLocation)
        #expect(parsed.blocks.count == expected.count, "\(markdown)", sourceLocation: sourceLocation)
        for (index, (got, want)) in zip(parsed.blocks, expected).enumerated() where !Self.looksSame(got, want) {
            Issue.record("Блок \(index): \(got) ≠ \(want)\n\(markdown)", sourceLocation: sourceLocation)
            return
        }
        #expect(parsed.simplifications.isEmpty, sourceLocation: sourceLocation)
    }

    /// Блоки выглядят одинаково: тот же вид, отступ, отметка и текст, у каждого видимого знака то же оформление.
    /// Пробел между двумя подчёркнутыми словами выгрузка пишет внутри подчёркивания, а скобки адреса кодирует (`%28`):
    /// читатель разницы не видит, поэтому пробелы и запись адреса не сравниваются.
    static func looksSame(_ a: ParsedBlock, _ b: ParsedBlock) -> Bool {
        a.kind == b.kind && a.indent == b.indent && a.isChecked == b.isChecked && a.pagePath == b.pagePath
            && a.text.string == b.text.string && appearance(of: a.text) == appearance(of: b.text)
    }

    private static func appearance(of text: InlineText) -> [Set<String>] {
        let units = Array(text.string.utf16)
        var styles = [Set<String>](repeating: [], count: units.count)
        for run in text.runs {
            let key = switch run.style {
            case .link(let url): "ссылка " + (url.absoluteString.removingPercentEncoding ?? url.absoluteString)
            default: "\(run.style)"
            }
            for index in max(run.start, 0)..<min(run.start + run.length, units.count) where units[index] != 0x20 && units[index] != 0x0A {
                styles[index].insert(key)
            }
        }
        return styles
    }

    private func makeBlock(_ kind: BlockKind, _ text: InlineText, indent: Int = 0, checked: Bool = false, link: UUID? = nil) -> Block {
        Block(pageId: UUID(), kind: kind, text: text, indent: indent, isChecked: checked, linkedPageId: link, sortKey: .between(nil, nil))
    }

    @Test("Все виды блоков, вложенность, переносы и служебные знаки")
    func roundTripAllKinds() {
        let sub = UUID()
        let trashed = UUID()
        let url = URL(string: "https://example.com/path?a=1&b=(2)")!
        let blocks: [Block] = [
            makeBlock(.heading1, InlineText("Заголовок *со* звёздочкой")),
            makeBlock(.paragraph, styled("жирный курсив код ссылка подчёркнутый", [
                (0, 6, .bold), (7, 6, .italic), (14, 3, .code), (18, 6, .link(url)), (25, 12, .underline),
            ])),
            makeBlock(.paragraph, InlineText("1. не список\n- и не пункт\n# и не заголовок\n> не цитата")),
            makeBlock(.paragraph, .empty),
            makeBlock(.heading2, InlineText("Два\nстроки")),
            makeBlock(.heading3, InlineText("Три")),
            makeBlock(.bulletItem, InlineText("маркер")),
            makeBlock(.numberedItem, InlineText("номер"), indent: 1),
            makeBlock(.numberedItem, InlineText("номер два\nс переносом"), indent: 1),
            makeBlock(.checkbox, InlineText("дело"), indent: 2, checked: true),
            makeBlock(.bulletItem, InlineText("снова маркер")),
            makeBlock(.numberedItem, InlineText("новый список")),
            makeBlock(.pageLink, .empty, link: sub),
            makeBlock(.pageLink, .empty, link: trashed),
            makeBlock(.paragraph, InlineText("a*b _c_ `d` [e] <f> ~g~ &amp; \\h 2) !")),
            makeBlock(.paragraph, styled("!ссылка", [(1, 6, .link(url))])),
            makeBlock(.checkbox, InlineText("")),
            makeBlock(.paragraph, .empty),
        ]
        roundTrip(blocks, linkTitles: [sub: ("Под [страница] (1)", "Папка/Под [страница] (1).md"), trashed: ("В корзине *важное*", nil)])
    }

    @Test("Пункты с номером 10 и больше, вложенное под ними")
    func roundTripTwoDigitNumbers() {
        var blocks = (1...11).map { makeBlock(.numberedItem, InlineText("п\($0)")) }
        blocks.insert(makeBlock(.bulletItem, InlineText("под десятым"), indent: 1), at: 10)
        blocks.append(makeBlock(.numberedItem, InlineText("под одиннадцатым"), indent: 1))
        roundTrip(blocks)
    }

    @Test("Случайные тексты с пересекающимся оформлением: 2 000 страниц")
    func roundTripRandom() {
        var random = SeededRandom(seed: 20261018)
        for _ in 0..<2_000 {
            roundTrip(randomBlocks(using: &random))
        }
    }

    private static let words = ["слово", "Notion", "ёж", "(скобка)", "точка.", "запятая,", "a*b", "snake_case", "100%",
                                "[x]", "`к`", "1.", "#", "😀", "«ёлка»", "x~y", "<тег>", "&amp;", "-", "+", "!", "?!", "\\", "мир"]
    private static let urls = [URL(string: "https://example.com")!, URL(string: "https://notion.so/a_b?c=(1)")!,
                               URL(string: "mailto:yury@example.com")!]

    private func randomText(using random: inout SeededRandom, allowBreaks: Bool) -> InlineText {
        let count = random.next(in: 1...7)
        var string = ""
        var wordRanges: [Range<Int>] = []
        for index in 0..<count {
            if index > 0 { string += allowBreaks && random.next(in: 0...5) == 0 ? "\n" : " " }
            let word = Self.words[random.next(in: 0...(Self.words.count - 1))]
            let start = string.utf16.count
            string += word
            wordRanges.append(start..<string.utf16.count)
        }
        var runs: [StyledRun] = []
        for _ in 0..<random.next(in: 0...4) {
            let first = random.next(in: 0...(count - 1))
            let last = random.next(in: first...(count - 1))
            let style: InlineStyle = switch random.next(in: 0...5) {
            case 0: .bold
            case 1: .italic
            case 2: .strikethrough
            case 3: .underline
            case 4: .code
            default: .link(Self.urls[random.next(in: 0...(Self.urls.count - 1))])
            }
            // Код и ссылка — на одно слово или на слова без переноса внутри: так их пишет и читает любая читалка.
            if case .link = style, Array(string.utf16)[wordRanges[first].lowerBound..<wordRanges[last].upperBound].contains(0x0A) { continue }
            if style == .code, first != last { continue }
            runs.append(StyledRun(start: wordRanges[first].lowerBound, length: wordRanges[last].upperBound - wordRanges[first].lowerBound, style: style))
        }
        return InlineText(string, runs: runs).normalized()
    }

    private func randomBlocks(using random: inout SeededRandom) -> [Block] {
        var blocks: [Block] = []
        var listIndent = -1
        for _ in 0..<random.next(in: 1...8) {
            let kind = [BlockKind.paragraph, .heading1, .heading2, .heading3, .bulletItem, .numberedItem, .checkbox][random.next(in: 0...6)]
            let isList = kind == .bulletItem || kind == .numberedItem || kind == .checkbox
            let indent = isList ? random.next(in: 0...(listIndent + 1)) : 0
            listIndent = isList ? indent : -1
            let text = random.next(in: 0...9) == 0 && kind == .paragraph ? .empty : randomText(using: &random, allowBreaks: !kind.isHeading)
            blocks.append(makeBlock(kind, text, indent: indent, checked: kind == .checkbox && random.next(in: 0...1) == 1))
        }
        return blocks
    }
}

/// Повторяемая последовательность случайных чисел (SplitMix64): упавший случай воспроизводится.
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func next(in range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.count))
    }
}
