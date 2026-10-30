import Foundation
import NotesCore
import Testing
@testable import PageMarkdown

/// Вставка ⌘V текста другой программы (ответ ИИ в Markdown, обычный текст со списками) — блоками страницы.
@Suite("Вставка текста блоками")
struct PastedTextTests {
    /// Ответ ИИ, как его кладёт в буфер кнопка «Копировать» Claude и ChatGPT.
    static let aiAnswer = """
    ## Как начать

    Сначала **установите** пакет и проверьте `версию`:

    1. Откройте терминал
    2. Выполните команду
       - для macOS: `brew install foo`
       - для Linux: *apt*
    3. Готово

    - [ ] Проверить
    - [x] Сделано

    > Совет: читайте ~~всё~~ [документацию](https://example.com).

    ```swift
    let x = 1
    ```

    ---

    #### Итог
    Всё работает.
    """

    private func blocks(_ text: String, hasRichText: Bool = false) -> [Block]? {
        PastedText.blocks(from: text, pageId: UUID(), hasRichText: hasRichText)
    }

    @Test("Ответ ИИ: заголовки, списки с вложенностью, чекбоксы, цитата, код с языком, разделитель")
    func aiAnswerBlocks() throws {
        let blocks = try #require(blocks(Self.aiAnswer))
        #expect(blocks.map(\.kind) == [.heading2, .paragraph, .numberedItem, .numberedItem, .bulletItem, .bulletItem, .numberedItem,
                                       .checkbox, .checkbox, .quote, .code, .divider, .heading3, .paragraph])
        #expect(blocks.map(\.indent) == [0, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0])
        #expect(blocks.map(\.isChecked) == [false, false, false, false, false, false, false, false, true, false, false, false, false, false])
        #expect(blocks[0].text.string == "Как начать")
        #expect(blocks[4].text.string == "для macOS: brew install foo")
        #expect(blocks[10].text.string == "let x = 1")
        #expect(blocks[10].props.language == "swift")
        #expect(blocks[12].text.string == "Итог")
    }

    @Test("Оформление в строке: жирный, курсив, код, зачёркнутый, ссылка")
    func inlineFormatting() throws {
        let blocks = try #require(blocks(Self.aiAnswer))
        #expect(blocks[1].text.string == "Сначала установите пакет и проверьте версию:")
        #expect(blocks[1].text.runs.map(\.style) == [.bold, .code])
        #expect(blocks[5].text.runs.map(\.style) == [.italic])
        let quote = blocks[9].text
        #expect(quote.string == "Совет: читайте всё документацию.")
        #expect(quote.runs.map(\.style) == [.strikethrough, .link(URL(string: "https://example.com")!)])
    }

    @Test("Таблица Markdown — блок таблицы с ячейками")
    func table() throws {
        let blocks = try #require(blocks("Итоги:\n\n| Имя | Балл |\n|---|---|\n| Аня | 5 |"))
        let flow = blocks.filter { $0.containerId == nil }
        #expect(flow.map(\.kind) == [.paragraph, .table])
        let cells = blocks.filter { $0.kind == .tableCell }.map(\.text.string)
        #expect(cells == ["Имя", "Балл", "Аня", "5"])
    }

    @Test("Пустые строки — только разделители: лишних пустых блоков нет")
    func noEmptyBlocks() throws {
        let blocks = try #require(blocks("# План\n\n\n\nПервый абзац\n\n\n\n\nВторой абзац\n\n"))
        #expect(blocks.map(\.kind) == [.heading1, .paragraph, .paragraph])
        #expect(blocks.map(\.text.string) == ["План", "Первый абзац", "Второй абзац"])
    }

    @Test("Одна строка — не блоки, даже с Markdown: вставится текстом в строку")
    func singleLine() {
        #expect(blocks("слово") == nil)
        #expect(blocks("**жирный** текст и `код`") == nil)
        #expect(blocks("# Заголовок\n") == nil)
        #expect(blocks("\n\n- пункт\n\n") == nil)
    }

    @Test("Обычный текст в несколько строк — строка свой абзац, пустые строки подряд — один пустой абзац, по краям — ни одного")
    func plainText() throws {
        let song = "\n\nКуплет первый,\nвторая строка\r\n\n\n  Припев *звёздочки* и file_name_x\n\nПоследняя # строка\n\n"
        let blocks = try #require(blocks(song))
        #expect(blocks.map(\.kind) == Array(repeating: .paragraph, count: 6))
        #expect(blocks.map(\.text.string) == ["Куплет первый,", "вторая строка", "", "Припев *звёздочки* и file_name_x", "", "Последняя # строка"])
        #expect(blocks.allSatisfy { $0.text.runs.isEmpty && $0.indent == 0 })
    }

    @Test("Строка из невидимых знаков (U+200B, неразрывный пробел) — пустая")
    func invisibleLinesAreBlank() throws {
        let blocks = try #require(blocks("а\n\u{200B}\n\u{00A0}\u{00A0}\n\u{FEFF}\nб"))
        #expect(blocks.map(\.text.string) == ["а", "", "б"])
        #expect(self.blocks("слово\n\u{200B}\n\u{00A0}") == nil)
        let markdown = try #require(self.blocks("# План\n\u{200B}\nтекст"))
        #expect(markdown.map(\.text.string) == ["План", "текст"])
    }

    @Test("Обычный текст рядом с оформленным (HTML, RTF) — не блоки: его вставит вставка с оформлением")
    func plainTextWithRichAlternative() {
        #expect(blocks("Первая строка письма\nВторая строка\n\nПодпись", hasRichText: true) == nil)
    }

    @Test("Обычный текст со строками-списками «•», «1)» — списки, остальное — абзацы, знаки текста не разбираются")
    func plainTextLists() throws {
        let text = "Покупки на неделю:\n• хлеб\n• file_name_x.txt\n  • вложенный *пункт\n• сыр\nИтого три."
        let blocks = try #require(blocks(text))
        #expect(blocks.map(\.kind) == [.paragraph, .bulletItem, .bulletItem, .bulletItem, .bulletItem, .paragraph])
        #expect(blocks.map(\.text.string) == ["Покупки на неделю:", "хлеб", "file_name_x.txt", "вложенный *пункт", "сыр", "Итого три."])
        #expect(blocks.map(\.indent) == [0, 0, 0, 1, 0, 0])
        #expect(blocks.allSatisfy { $0.text.runs.isEmpty })
        let numbered = try #require(self.blocks("Шаги:\n1) открыть\n2) закрыть"))
        #expect(numbered.map(\.kind) == [.paragraph, .numberedItem, .numberedItem])
    }

    @Test("Реплики диалога с тире — не список: абзацы")
    func dialogue() throws {
        let blocks = try #require(blocks("— Привет, — сказал он.\n— Здравствуй.\n– И тебе."))
        #expect(blocks.map(\.kind) == [.paragraph, .paragraph, .paragraph])
        #expect(blocks.map(\.text.string) == ["— Привет, — сказал он.", "— Здравствуй.", "– И тебе."])
    }

    @Test("Есть HTML или RTF: блоками — только явный Markdown, одни списки «1.» отдаются оформленному тексту")
    func richTextAlternative() throws {
        #expect(blocks("Шаги:\n1. открыть\n2. закрыть", hasRichText: true) == nil)
        #expect(blocks("Покупки:\n• хлеб\n• сыр", hasRichText: true) == nil)
        let markdown = try #require(blocks("## Шаги\n\n1. **открыть**\n2. закрыть", hasRichText: true))
        #expect(markdown.map(\.kind) == [.heading2, .numberedItem, .numberedItem])
    }
}
