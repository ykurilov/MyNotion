import Foundation
import Testing
import NotesCore
@testable import MarkdownExport

/// Запись блоков страницы в Markdown по таблице contracts/files-import-export.md.
@Suite("Блоки в Markdown")
struct MarkdownBlockWriterTests {
    private let pageId = UUID()
    private let writer = MarkdownBlockWriter()

    private func block(
        _ kind: BlockKind = .paragraph, _ text: String = "", runs: [StyledRun] = [],
        indent: Int = 0, checked: Bool = false, link: UUID? = nil
    ) -> Block {
        Block(pageId: pageId, kind: kind, text: InlineText(text, runs: runs), indent: indent, isChecked: checked,
              linkedPageId: link, sortKey: .between(nil, nil))
    }

    private func markdown(_ blocks: Block..., links: [UUID: PageLinkTarget] = [:]) -> String {
        writer.markdown(for: blocks, resolveLink: { links[$0] })
    }

    private func inline(_ text: String, _ runs: StyledRun...) -> String {
        markdown(block(.paragraph, text, runs: runs))
    }

    private func run(_ start: Int, _ length: Int, _ style: InlineStyle) -> StyledRun {
        StyledRun(start: start, length: length, style: style)
    }

    // MARK: Типы блоков

    @Test("Абзацы разделены пустой строкой")
    func paragraphs() {
        #expect(markdown(block(.paragraph, "Первый"), block(.paragraph, "Второй")) == "Первый\n\nВторой\n")
    }

    @Test("Заголовки — #, ##, ###")
    func headings() {
        #expect(markdown(block(.heading1, "А"), block(.heading2, "Б"), block(.heading3, "В")) == "# А\n\n## Б\n\n### В\n")
    }

    @Test("Маркированный список: вложенный пункт сдвинут на ширину «- »")
    func bulletsNest() {
        let text = markdown(block(.bulletItem, "a"), block(.bulletItem, "b", indent: 1), block(.bulletItem, "c", indent: 2),
                            block(.bulletItem, "d"))
        #expect(text == "- a\n  - b\n    - c\n- d\n")
    }

    @Test("Нумерованный список считает пункты на каждом уровне отдельно")
    func numberedCountsPerLevel() {
        let text = markdown(block(.numberedItem, "a"), block(.numberedItem, "b", indent: 1), block(.numberedItem, "c", indent: 1),
                            block(.numberedItem, "d"), block(.numberedItem, "e", indent: 1))
        #expect(text == "1. a\n   1. b\n   2. c\n2. d\n   1. e\n")
    }

    @Test("Нумерация начинается заново после другого блока")
    func numberingRestartsAfterOtherBlock() {
        let text = markdown(block(.numberedItem, "a"), block(.numberedItem, "b"), block(.paragraph, "между"), block(.numberedItem, "c"))
        #expect(text == "1. a\n2. b\n\nмежду\n\n1. c\n")
    }

    @Test("Чекбоксы: - [ ] и - [x]")
    func checkboxes() {
        let text = markdown(block(.checkbox, "сделать"), block(.checkbox, "готово", checked: true), block(.checkbox, "вложенное", indent: 1))
        #expect(text == "- [ ] сделать\n- [x] готово\n  - [ ] вложенное\n")
    }

    @Test("Список и абзац разделены пустой строкой, пункты разных списков — нет")
    func listsAndParagraphs() {
        let text = markdown(block(.paragraph, "до"), block(.bulletItem, "a"), block(.checkbox, "b"), block(.paragraph, "после"))
        #expect(text == "до\n\n- a\n- [ ] b\n\nпосле\n")
    }

    @Test("Пункт другого вида на том же уровне — новый список; вложенный пункт другого вида — нет")
    func listFamilies() {
        #expect(markdown(block(.bulletItem, "a"), block(.numberedItem, "b")) == "- a\n\n1. b\n")
        #expect(markdown(block(.bulletItem, "a"), block(.numberedItem, "b", indent: 1), block(.bulletItem, "c"))
                == "- a\n  1. b\n- c\n")
        #expect(markdown(block(.numberedItem, "a"), block(.bulletItem, "b", indent: 1), block(.numberedItem, "c"))
                == "1. a\n   - b\n2. c\n")
    }


    @Test("Вложенный пункт сдвинут на ширину маркера родителя: «- » — 2, «1. » — 3, «10. » — 4")
    func nestingFollowsParentMarkerWidth() {
        #expect(markdown(block(.numberedItem, "a"), block(.bulletItem, "b", indent: 1)) == "1. a\n   - b\n")
        #expect(markdown(block(.checkbox, "a"), block(.bulletItem, "b", indent: 1)) == "- [ ] a\n  - b\n")
        #expect(markdown(block(.bulletItem, "a"), block(.numberedItem, "b", indent: 1), block(.numberedItem, "c", indent: 1))
                == "- a\n  1. b\n  2. c\n")
        #expect(markdown(block(.numberedItem, "a"), block(.bulletItem, "b", indent: 1), block(.numberedItem, "c", indent: 2))
                == "1. a\n   - b\n     1. c\n")
    }

    @Test("Десятый пункт нумерованного списка: вложенное — на 4 пробела, и у одиннадцатого тоже")
    func nestingUnderTwoDigitNumbers() {
        var blocks = (1...9).map { block(.numberedItem, "п\($0)") }
        blocks.append(block(.numberedItem, "п10"))
        blocks.append(block(.bulletItem, "вложенный", indent: 1))
        blocks.append(block(.numberedItem, "п11"))
        blocks.append(block(.numberedItem, "вложенный нумерованный", indent: 1))
        let text = writer.markdown(for: blocks, resolveLink: { _ in nil })
        #expect(text.hasSuffix("10. п10\n    - вложенный\n11. п11\n    1. вложенный нумерованный\n"))
    }

    @Test("Ширину берёт ближайший предок, пропущенный уровень считается пунктом «- »")
    func nestingWithSkippedLevel() {
        #expect(markdown(block(.bulletItem, "a"), block(.bulletItem, "c", indent: 2)) == "- a\n    - c\n")
        #expect(markdown(block(.numberedItem, "a"), block(.bulletItem, "b", indent: 1), block(.numberedItem, "c"),
                         block(.bulletItem, "d", indent: 1)) == "1. a\n   - b\n2. c\n   - d\n")
    }

    @Test("Перенос строки во вложенном пункте — с отступом его текста")
    func softBreakInNestedItems() {
        #expect(markdown(block(.numberedItem, "a"), block(.bulletItem, "b\nc", indent: 1)) == "1. a\n   - b  \n     c\n")
    }

    @Test("Отступ есть только у списков и чекбоксов")
    func indentOnlyForLists() {
        #expect(markdown(block(.paragraph, "текст", indent: 2)) == "текст\n")
    }

    @Test("Пустой абзац — лишняя пустая строка")
    func emptyParagraph() {
        #expect(markdown(block(.paragraph, "a"), block(.paragraph, ""), block(.paragraph, "b")) == "a\n\n\nb\n")
    }

    @Test("Пустая страница — пустой текст, пустой абзац в конце не оставляет хвоста")
    func trailingEmptyParagraphs() {
        #expect(markdown(block(.paragraph, "")) == "")
        #expect(markdown(block(.paragraph, "a"), block(.paragraph, "")) == "a\n")
    }

    @Test("Пустой пункт списка остаётся пунктом")
    func emptyListItem() {
        #expect(markdown(block(.bulletItem, ""), block(.checkbox, "")) == "- \n- [ ] \n")
    }

    // MARK: Ссылки на подстраницы

    @Test("Ссылка на подстраницу — относительным путём")
    func pageLink() {
        let target = UUID()
        let text = markdown(block(.pageLink, link: target), links: [target: PageLinkTarget(title: "Идеи", path: "MyNotion/Идеи.md")])
        #expect(text == "[Идеи](MyNotion/Идеи.md)\n")
    }

    @Test("В пути пробелы и скобки кодируются, кириллица остаётся")
    func pageLinkPathEncoding() {
        let target = UUID()
        let text = markdown(block(.pageLink, link: target),
                            links: [target: PageLinkTarget(title: "Идеи", path: "../Мои идеи (2).md")])
        #expect(text == "[Идеи](../Мои%20идеи%20%282%29.md)\n")
    }

    @Test("Скобки в названии подстраницы экранируются")
    func pageLinkTitleEscaping() {
        let target = UUID()
        let text = markdown(block(.pageLink, link: target), links: [target: PageLinkTarget(title: "План [черновик]", path: "План.md")])
        #expect(text == "[План \\[черновик\\]](План.md)\n")
    }

    @Test("Подстраницы нет в выгрузке — просто название")
    func pageLinkWithoutFile() {
        let target = UUID()
        #expect(markdown(block(.pageLink, link: target), links: [target: PageLinkTarget(title: "Удалённая", path: nil)]) == "Удалённая\n")
    }

    @Test("Ссылка на неизвестную страницу ничего не пишет")
    func pageLinkToUnknownPage() {
        #expect(markdown(block(.paragraph, "a"), block(.pageLink, link: UUID()), block(.paragraph, "b")) == "a\n\nb\n")
    }

    // MARK: Оформление в строке

    @Test("Жирный, курсив, зачёркнутый, код")
    func basicStyles() {
        #expect(inline("жирный", run(0, 6, .bold)) == "**жирный**\n")
        #expect(inline("курсив", run(0, 6, .italic)) == "*курсив*\n")
        #expect(inline("старое", run(0, 6, .strikethrough)) == "~~старое~~\n")
        #expect(inline("код", run(0, 3, .code)) == "`код`\n")
    }

    @Test("Подчёркивание — <u>…</u>")
    func underline() {
        #expect(inline("важно", run(0, 5, .underline)) == "<u>важно</u>\n")
    }

    @Test("Ссылка — [текст](адрес)")
    func link() {
        let url = URL(string: "https://example.com/a_b")!
        #expect(inline("сайт", run(0, 4, .link(url))) == "[сайт](https://example.com/a_b)\n")
    }

    @Test("Скобки в адресе ссылки кодируются")
    func linkWithParentheses() {
        let url = URL(string: "https://example.com/a_(b)")!
        #expect(inline("сайт", run(0, 4, .link(url))) == "[сайт](https://example.com/a_%28b%29)\n")
    }

    @Test("Оформлена часть текста")
    func partialStyle() {
        #expect(inline("до жирный после", run(3, 6, .bold)) == "до **жирный** после\n")
    }

    @Test("Один стиль внутри другого")
    func nestedStyles() {
        #expect(inline("abcdefgh", run(0, 8, .bold), run(3, 2, .italic)) == "**abc*de*fgh**\n")
    }

    @Test("Жирный курсив и ссылка с жирным текстом")
    func combinedStyles() {
        let url = URL(string: "https://example.com")!
        #expect(inline("ab", run(0, 2, .bold), run(0, 2, .italic)) == "***ab***\n")
        #expect(inline("ab", run(0, 2, .link(url)), run(0, 2, .bold)) == "[**ab**](https://example.com)\n")
    }

    @Test("Код внутри жирного, внутри кода ничего не экранируется")
    func codeInsideBold() {
        #expect(inline("a*b", run(0, 3, .bold), run(0, 3, .code)) == "**`a*b`**\n")
    }

    @Test("В коде есть обратная кавычка — рамка длиннее")
    func codeWithBacktick() {
        #expect(inline("a`b", run(0, 3, .code)) == "``a`b``\n")
    }

    @Test("Пробелы на краю оформления выносятся за знаки")
    func spacesOutsideDelimiters() {
        #expect(inline("жирный текст", run(0, 7, .bold)) == "**жирный** текст\n")
        #expect(inline("а  б", run(1, 2, .bold)) == "а  б\n")
        #expect(inline("a б", run(0, 2, .italic)) == "*a* б\n")
    }

    @Test("Соседние отрезки разных стилей")
    func adjacentStyles() {
        #expect(inline("абвг", run(0, 2, .bold), run(2, 2, .strikethrough)) == "**аб**~~вг~~\n")
    }

    // MARK: Пересекающиеся и соседние стили

    @Test("Частично перекрытые стили: общая часть внутри, остаток — тегом, без «****»")
    func partiallyOverlappingStyles() {
        #expect(inline("abc", run(0, 2, .bold), run(1, 2, .italic)) == "**a*b***<em>c</em>\n")
        #expect(inline("abc", run(0, 2, .italic), run(1, 2, .bold)) == "*a**b***<strong>c</strong>\n")
    }

    @Test("Ссылка и жирный частично перекрыты: знаки ссылки разводят звёздочки")
    func linkPartiallyOverlappingBold() {
        let url = URL(string: "https://e.com")!
        #expect(inline("abc", run(0, 2, .link(url)), run(1, 2, .bold)) == "[a**b**](https://e.com)**c**\n")
    }

    @Test("Восклицательный знак перед ссылкой экранируется, иначе читалка сделает картинку")
    func exclamationBeforeLink() {
        let url = URL(string: "https://e.com")!
        #expect(inline("!а", run(1, 1, .link(url))) == "\\![а](https://e.com)\n")
    }

    @Test("Стыки между знаками препинания пишутся тегами: звёздочки там читалки сопоставляют по-разному")
    func punctuationOnBothSides() {
        let out = inline("«-*", run(2, 1, .italic), run(2, 1, .bold), run(0, 2, .bold), run(0, 1, .italic))
        #expect(!out.contains("***«*"))
        #expect(out.contains("<em>") || out.contains("<strong>"))
    }

    @Test("Соседние стили с одинаковым знаком: второй — тегом, иначе звёздочки сливаются")
    func adjacentStylesWithSameMark() {
        #expect(inline("абвг", run(0, 2, .italic), run(2, 2, .bold)) == "*аб*<strong>вг</strong>\n")
        #expect(inline("абвг", run(0, 2, .bold), run(2, 2, .italic)) == "**аб**<em>вг</em>\n")
        #expect(inline("абвг", run(0, 2, .strikethrough), run(2, 2, .strikethrough)) == "~~абвг~~\n")
    }

    @Test("Соседние отрезки одного стиля сливаются, пробел между ними остаётся внутри")
    func sameStyleNeighborsMerge() {
        #expect(inline("абвг", run(0, 2, .bold), run(2, 2, .bold)) == "**абвг**\n")
        #expect(inline("а б", run(0, 1, .bold), run(2, 1, .bold)) == "**а б**\n")
    }

    @Test("Пустые знаки не пишутся: оформлены только пробелы или пустой отрезок")
    func noEmptyMarkers() {
        #expect(inline("а б", run(1, 1, .italic)) == "а б\n")
        #expect(inline("а б", run(1, 0, .bold)) == "а б\n")
        #expect(inline("а   б", run(1, 3, .bold), run(1, 3, .italic)) == "а   б\n")
    }

    @Test("Жирный внутри курсива: порядок знаков по длине охвата")
    func boldInsideItalic() {
        #expect(inline("ab", run(0, 2, .italic), run(0, 1, .bold)) == "***a**b*\n")
        #expect(inline("abcde", run(0, 5, .italic), run(1, 3, .bold)) == "*a**bcd**e*\n")
    }

    @Test("Знак у скобки или кавычки при букве снаружи читалка не примет: такое оформление — тегом")
    func punctuationAtEdgeNextToLetter() {
        #expect(inline("«а»б", run(0, 3, .bold)) == "<strong>«а»</strong>б\n")
        #expect(inline("б(а)", run(1, 3, .bold)) == "б<strong>(а)</strong>\n")
        #expect(inline("б,в", run(1, 1, .italic)) == "б<em>,</em>в\n")
        // Рядом пробел или край строки — обычные знаки подходят.
        #expect(inline("(а) б", run(0, 3, .italic)) == "*(а)* б\n")
        #expect(inline("абв", run(1, 1, .bold)) == "а**б**в\n")
    }

    @Test("Неразрывный пробел на краю оформления тоже выносится за знаки")
    func nonBreakingSpaceOutsideDelimiters() {
        #expect(inline("а\u{00A0}б", run(0, 2, .bold)) == "**а**\u{00A0}б\n")
    }

    @Test("Оформление в пункте списка, заголовке и чекбоксе")
    func styleInsideBlocks() {
        let bold = [run(0, 1, .bold)]
        #expect(markdown(block(.bulletItem, "а", runs: bold)) == "- **а**\n")
        #expect(markdown(block(.heading2, "а", runs: bold)) == "## **а**\n")
        #expect(markdown(block(.checkbox, "а", runs: bold, checked: true)) == "- [x] **а**\n")
    }

    // MARK: Экранирование

    @Test("Знаки Markdown в обычном тексте экранируются")
    func escapesInlineMarkers() {
        #expect(inline("2 * 3 = 6") == "2 \\* 3 = 6\n")
        #expect(inline("_важно_") == "\\_важно\\_\n")
        #expect(inline("a\\b") == "a\\\\b\n")
        #expect(inline("`x`") == "\\`x\\`\n")
        #expect(inline("~~x~~") == "\\~\\~x\\~\\~\n")
        #expect(inline("[a](b)") == "\\[a\\](b)\n")
        #expect(inline("<b>x</b>") == "\\<b>x\\</b>\n")
        #expect(inline("&copy;") == "\\&copy;\n")
    }

    @Test("Подчёркивание внутри слова остаётся как есть")
    func underscoreInsideWord() {
        #expect(inline("snake_case_name") == "snake_case_name\n")
        #expect(inline("100% и #1, цена: 5$") == "100% и #1, цена: 5$\n")
    }

    @Test("Начало строки не превращается в заголовок, список, цитату или нумерацию")
    func escapesLineStart() {
        #expect(inline("# не заголовок") == "\\# не заголовок\n")
        #expect(inline("- не список") == "\\- не список\n")
        #expect(inline("+ не список") == "\\+ не список\n")
        #expect(inline("1. не нумерация") == "1\\. не нумерация\n")
        #expect(inline("12) не нумерация") == "12\\) не нумерация\n")
        #expect(inline("> не цитата") == "\\> не цитата\n")
        #expect(inline("---") == "\\---\n")
        #expect(inline("-5 градусов") == "-5 градусов\n")
        #expect(inline("2024. год") == "2024\\. год\n")
        #expect(inline("2.5 литра") == "2.5 литра\n")
    }

    @Test("Начало строки экранируется и внутри пункта, и после переноса строки")
    func escapesLineStartInsideItemsAndAfterBreaks() {
        #expect(markdown(block(.bulletItem, "# x")) == "- \\# x\n")
        #expect(markdown(block(.paragraph, "a\n# b")) == "a  \n\\# b\n")
        #expect(markdown(block(.heading1, "# x")) == "# \\# x\n")
    }

    @Test("Экранирование не мешает оформлению: звёздочка в жирном тексте")
    func escapesInsideStyledText() {
        #expect(inline("a*b", run(0, 3, .bold)) == "**a\\*b**\n")
    }

    // MARK: Перенос строки внутри блока

    @Test("Перенос строки — два пробела в конце строки")
    func softBreakInParagraph() {
        #expect(markdown(block(.paragraph, "строка\nвторая")) == "строка  \nвторая\n")
    }

    @Test("Следующая строка пункта — с отступом его текста")
    func softBreakInListItems() {
        #expect(markdown(block(.bulletItem, "a\nb")) == "- a  \n  b\n")
        #expect(markdown(block(.bulletItem, "a\nb", indent: 1)) == "  - a  \n    b\n")
        #expect(markdown(block(.numberedItem, "a\nb")) == "1. a  \n   b\n")
        #expect(markdown(block(.checkbox, "a\nb")) == "- [ ] a  \n      b\n")
    }

    @Test("Перенос внутри оформленного текста")
    func softBreakInsideStyle() {
        #expect(inline("а\nб", run(0, 3, .bold)) == "**а  \nб**\n")
    }

    @Test("В заголовке перенос строки становится пробелом")
    func softBreakInHeading() {
        #expect(markdown(block(.heading1, "а\nб")) == "# а б\n")
    }
}
