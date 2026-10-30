import AppKit
import Foundation
import Testing
@testable import NotesCore
@testable import PageEditor

/// Вставка текста другой программы блоками (Markdown ответа ИИ): разбор подменён, проверяется, как блоки встают на страницу.
@MainActor
@Suite("Вставка блоками")
struct PasteBlocksTests {
    typealias Spec = EditorFixture.Spec

    /// Разбор, который на текст «markdown» отвечает этими блоками, а на прочий — «вставлять текстом».
    private static func reader(_ blocks: [Block]) -> PageTextView.PastedTextReader {
        { text, _, _, _, _ in text == "markdown" ? blocks : nil }
    }

    private static func block(_ kind: BlockKind, _ text: String = "", indent: Int = 0, runs: [StyledRun] = []) -> Block {
        Block(pageId: UUID(), kind: kind, text: InlineText(text, runs: runs), indent: indent, sortKey: .between(nil, nil))
    }

    /// Разбор обычного текста: строка — абзац, как у `PastedText` для текста без Markdown.
    private static let plainLines: PageTextView.PastedTextReader = { text, _, _, _, _ in
        text.components(separatedBy: "\n").map { block(.paragraph, $0) }
    }

    private static func pasteboard(_ string: String) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("MyNotionTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
        return pasteboard
    }

    @Test("В пустой абзац: блоки встают целиком, первый — вместо пустого; одна ⌘Z отменяет всё")
    func intoEmptyParagraph() throws {
        let editor = try EditorFixture([.paragraph("Выше"), .paragraph()])
        let original = editor.document.blocks[1].id
        editor.textView.pastedTextReader = Self.reader([
            Self.block(.heading2, "Заголовок"),
            Self.block(.bulletItem, "жирный пункт", runs: [StyledRun(start: 0, length: 6, style: .bold)]),
            Self.block(.bulletItem, "вложенный", indent: 1),
            Self.block(.paragraph, "Текст"),
        ])
        editor.placeCaret(inBlock: 1)

        editor.step { editor.textView.paste(from: Self.pasteboard("markdown")) }

        #expect(editor.kinds == [.paragraph, .heading2, .bulletItem, .bulletItem, .paragraph])
        #expect(editor.texts == ["Выше", "Заголовок", "жирный пункт", "вложенный", "Текст"])
        #expect(editor.indents == [0, 0, 0, 1, 0])
        #expect(editor.document.blocks[1].id == original)
        #expect(editor.document.blocks[2].text.runs == [StyledRun(start: 0, length: 6, style: .bold)])
        #expect(editor.textView.selectedRange() == NSRange(location: editor.textLocation(ofBlock: 4) + 5, length: 0), "Курсор — в конце вставленного")

        editor.undo()
        #expect(editor.kinds == [.paragraph, .paragraph])
        #expect(editor.texts == ["Выше", ""])
        editor.redo()
        #expect(editor.texts == ["Выше", "Заголовок", "жирный пункт", "вложенный", "Текст"])
    }

    @Test("Из Notion в Chrome: разбор получает буфер Chromium, пустые блоки вставки встают пустыми абзацами")
    func notionEmptyBlocks() throws {
        let editor = try EditorFixture([.paragraph("Выше"), .paragraph()])
        let notionData = Data("данные Notion".utf8)
        var received: Data?
        editor.textView.pastedTextReader = { _, _, _, _, webCustomData in
            received = webCustomData
            return [Self.block(.paragraph), Self.block(.paragraph, "А"), Self.block(.paragraph), Self.block(.paragraph),
                    Self.block(.bulletItem, "Б"), Self.block(.paragraph)]
        }
        let pasteboard = Self.pasteboard("А\nБ")
        pasteboard.setData(notionData, forType: NSPasteboard.PasteboardType("org.chromium.web-custom-data"))
        editor.placeCaret(inBlock: 1)

        editor.step { editor.textView.paste(from: pasteboard) }

        #expect(received == notionData)
        #expect(editor.kinds == [.paragraph, .paragraph, .paragraph, .paragraph, .paragraph, .bulletItem, .paragraph])
        #expect(editor.texts == ["Выше", "", "А", "", "", "Б", ""])
    }

    @Test("В середину абзаца: первая строка сливается с текстом до курсора, последняя — с хвостом, как в Notion")
    func intoMiddleOfParagraph() throws {
        let editor = try EditorFixture([.paragraph("НачалоКонец")])
        editor.textView.pastedTextReader = Self.reader([
            Self.block(.paragraph, " один"), Self.block(.bulletItem, "два"), Self.block(.paragraph, "три "),
        ])
        editor.placeCaret(inBlock: 0, at: 6)

        editor.step { editor.textView.paste(from: Self.pasteboard("markdown")) }

        #expect(editor.kinds == [.paragraph, .bulletItem, .paragraph])
        #expect(editor.texts == ["Начало один", "два", "три Конец"])
        #expect(editor.textView.selectedRange() == NSRange(location: editor.textLocation(ofBlock: 2) + 4, length: 0))
        editor.undo()
        #expect(editor.texts == ["НачалоКонец"])
    }

    @Test("Блок пункта списка: первый абзац вставки продолжает пункт, отступы вставки — от его отступа")
    func intoListItem() throws {
        let editor = try EditorFixture([.bullet("Пункт: ", indent: 1)])
        editor.textView.pastedTextReader = Self.reader([Self.block(.paragraph, "раз"), Self.block(.bulletItem, "два", indent: 1)])
        editor.placeCaret(inBlock: 0, at: nil)

        editor.step { editor.textView.paste(from: Self.pasteboard("markdown")) }

        #expect(editor.kinds == [.bulletItem, .bulletItem])
        #expect(editor.texts == ["Пункт: раз", "два"])
        #expect(editor.indents == [1, 2])
    }

    @Test("Последний блок вставки без текста (код): хвост абзаца — отдельным абзацем под ним")
    func codeAtEnd() throws {
        let editor = try EditorFixture([.paragraph("НачалоКонец")])
        var code = Self.block(.code, "let x = 1")
        code.props.language = "swift"
        editor.textView.pastedTextReader = Self.reader([Self.block(.paragraph, " текст"), code])
        editor.placeCaret(inBlock: 0, at: 6)

        editor.step { editor.textView.paste(from: Self.pasteboard("markdown")) }

        #expect(editor.kinds == [.paragraph, .code, .paragraph])
        #expect(editor.texts == ["Начало текст", "let x = 1", "Конец"])
        #expect(editor.document.blocks[1].props.language == "swift")
        editor.undo()
        #expect(editor.texts == ["НачалоКонец"])
    }

    @Test("Таблица вставки встаёт вместе с ячейками и отменяется той же ⌘Z")
    func tableWithCells() throws {
        let editor = try EditorFixture([.paragraph()])
        var table = Block(pageId: editor.pageId, kind: .table, sortKey: .between(nil, nil))
        table.props = .defaults(for: .table)
        let contents = TableGrid.contents(ofTable: table, cells: [[InlineText("Имя"), InlineText("Балл")], [InlineText("Аня"), InlineText("5")]])
        editor.textView.pastedTextReader = Self.reader([Self.block(.paragraph, "Итоги"), table] + contents)
        editor.placeCaret(inBlock: 0)

        editor.step { editor.textView.paste(from: Self.pasteboard("markdown")) }

        #expect(editor.kinds == [.paragraph, .table, .paragraph])
        let pasted = editor.document.blocks[1]
        let rows = editor.document.flow(pasted.id)
        #expect(rows.filter { $0.kind == .tableRow }.count == 2)
        let cells = rows.filter { $0.kind == .tableRow }.flatMap { editor.document.flow($0.id) }.map(\.text.string)
        #expect(cells == ["Имя", "Балл", "Аня", "5"])
        editor.undo()
        #expect(editor.kinds == [.paragraph])
        #expect(editor.texts == [""])
    }

    /// Таблица вставки из трёх столбцов; `widths` — ширины столбцов, `nil` — у столбца ширины нет, как у таблицы из чужого Markdown.
    private static func table(widths: [Double?], in pageId: UUID) -> [Block] {
        var table = Block(pageId: pageId, kind: .table, sortKey: .between(nil, nil))
        table.props = .defaults(for: .table)
        let cells = [["Показатель", "Что оценивает", "Формула"], ["ROI", "Весь проект или запуск", "Доход ÷ инвестиции"]].map { $0.map { InlineText($0) } }
        var contents = TableGrid.contents(ofTable: table, cells: cells)
        let columns = contents.indices.filter { contents[$0].kind == .tableColumn }
        for (position, index) in columns.enumerated() { contents[index].props.width = widths[position] }
        return [table] + contents
    }

    @Test("Таблица без ширин столбцов занимает ширину текста страницы: столбцы делят её поровну")
    func tableWithoutWidthsFillsPage() throws {
        let editor = try EditorFixture([.paragraph()])
        editor.textView.pastedTextReader = Self.reader(Self.table(widths: [nil, nil, nil], in: editor.pageId))
        editor.placeCaret(inBlock: 0)

        editor.step { editor.textView.paste(from: Self.pasteboard("markdown")) }
        editor.layoutViewport()

        let table = try #require(editor.document.blocks.first { $0.kind == .table })
        let grid = try #require(editor.document.tableGrid(table.id))
        let container = try #require(editor.textView.textContainer)
        let line = (container.size.width - 2 * container.lineFragmentPadding).rounded(.down)
        let widths = (0..<grid.columnCount).map { grid.width(ofColumn: $0) }
        #expect(widths.count == 3)
        #expect(Set(widths).count == 1)
        #expect(widths.reduce(0, +) <= Double(line) && widths.reduce(0, +) > Double(line) - 3, "\(widths) в строке \(line)")
        let view = try #require(editor.textView.tableView(for: table.id))
        #expect(view.tableLayout.columnWidths.map(Double.init) == widths)
    }

    @Test("Выставленные ширины столбцов вставка не меняет")
    func tableWithWidthsKeepsThem() throws {
        let editor = try EditorFixture([.paragraph()])
        editor.textView.pastedTextReader = Self.reader(Self.table(widths: [80, 200, 90], in: editor.pageId))
        editor.placeCaret(inBlock: 0)

        editor.step { editor.textView.paste(from: Self.pasteboard("markdown")) }

        let table = try #require(editor.document.blocks.first { $0.kind == .table })
        let grid = try #require(editor.document.tableGrid(table.id))
        #expect((0..<grid.columnCount).map { grid.width(ofColumn: $0) } == [80, 200, 90])
    }

    @Test("Выделение через несколько блоков заменяется вставкой")
    func overSelection() throws {
        let editor = try EditorFixture([.paragraph("один два"), .paragraph("три"), .paragraph("четыре пять")])
        editor.textView.pastedTextReader = Self.reader([Self.block(.heading1, "А"), Self.block(.paragraph, "Б")])
        let start = editor.textLocation(ofBlock: 0) + 5
        let end = editor.textLocation(ofBlock: 2) + 7
        editor.textView.setSelectedRange(NSRange(location: start, length: end - start))

        editor.step { editor.textView.paste(from: Self.pasteboard("markdown")) }

        #expect(editor.texts == ["один А", "Бпять"])
        editor.undo()
        #expect(editor.texts == ["один два", "три", "четыре пять"])
    }

    @Test("Разбор ответил «текстом» — вставка как раньше, в строку")
    func readerDeclines() throws {
        let editor = try EditorFixture([.paragraph("см. ")])
        editor.textView.pastedTextReader = Self.reader([Self.block(.heading1, "не должно")])
        editor.placeCaret(inBlock: 0, at: nil)

        editor.step { editor.textView.paste(from: Self.pasteboard("просто слово")) }

        #expect(editor.texts == ["см. просто слово"])
    }

    @Test("«Вставить без форматирования» (⌥⇧⌘V) не разбирает Markdown")
    func pasteAsPlainText() throws {
        let editor = try EditorFixture([.paragraph()])
        var asked = false
        editor.textView.pastedTextReader = { _, _, _, _, _ in
            asked = true
            return [Self.block(.heading1, "не должно")]
        }
        editor.placeCaret(inBlock: 0)

        editor.step { editor.textView.paste(from: Self.pasteboard("## Заголовок\n**жирный**"), asPlainText: true) }

        #expect(!asked)
        #expect(editor.kinds.allSatisfy { $0 == .paragraph })
        #expect(editor.texts == ["## Заголовок", "**жирный**"])
    }

    // MARK: Тип новых строк — как у Enter в блоке, куда вставляют

    @Test("Строки в середину пункта, задачи и цитаты продолжают их тип; хвост задачи — без галочки")
    func linesContinueListItemsTasksAndQuotes() throws {
        let editor = try EditorFixture([.bullet("одиндва"), .checkbox("делоещё", checked: true), Spec(kind: .quote, text: "цитата")])
        editor.textView.pastedTextReader = Self.plainLines

        editor.placeCaret(inBlock: 0, at: 4)
        editor.step { editor.textView.paste(from: Self.pasteboard("x\ny\nz")) }
        #expect(editor.kinds == [.bulletItem, .bulletItem, .bulletItem, .checkbox, .quote])
        #expect(editor.texts == ["одинx", "y", "zдва", "делоещё", "цитата"])

        editor.placeCaret(inBlock: 3, at: 4)
        editor.step { editor.textView.paste(from: Self.pasteboard("x\ny")) }
        #expect(editor.kinds == [.bulletItem, .bulletItem, .bulletItem, .checkbox, .checkbox, .quote])
        #expect(editor.document.blocks[3...4].map(\.isChecked) == [true, false])
        #expect(editor.texts[3...4] == ["делоx", "yещё"])

        editor.placeCaret(inBlock: 5, at: nil)
        editor.step { editor.textView.paste(from: Self.pasteboard("x\ny")) }
        #expect(editor.kinds.suffix(2) == [.quote, .quote])
        #expect(editor.texts.suffix(2) == ["цитатаx", "y"])

        editor.undo()
        #expect(editor.kinds.suffix(1) == [.quote])
        #expect(editor.texts.suffix(1) == ["цитата"])
    }

    @Test("Вставка в заголовок: новые строки — абзацы, хвост остаётся заголовком")
    func headingTailStaysHeading() throws {
        let editor = try EditorFixture([.heading(1, "Заголовок"), .heading(2, "Итог")])
        editor.textView.pastedTextReader = Self.plainLines

        editor.placeCaret(inBlock: 0, at: 3)
        editor.step { editor.textView.paste(from: Self.pasteboard("x\ny\nz")) }
        #expect(editor.kinds == [.heading1, .paragraph, .heading1, .heading2])
        #expect(editor.texts == ["Загx", "y", "zоловок", "Итог"])

        editor.placeCaret(inBlock: 3, at: nil)
        editor.step { editor.textView.paste(from: Self.pasteboard("x\ny")) }
        #expect(editor.kinds.suffix(2) == [.heading2, .paragraph])
    }

    // MARK: Вложенные блоки

    @Test("Вложенные блоки остаются у своего блока: вставка встаёт после них; одна ⌘Z")
    func childrenStayWithTheirBlock() throws {
        let editor = try EditorFixture([.bullet("a"), .bullet("b", indent: 1), .paragraph("c")])
        let childId = editor.document.blocks[1].id
        editor.textView.pastedTextReader = Self.plainLines
        editor.placeCaret(inBlock: 0, at: nil)

        editor.step { editor.textView.paste(from: Self.pasteboard("x\ny")) }

        #expect(editor.texts == ["ax", "b", "y", "c"])
        #expect(editor.indents == [0, 1, 0, 0])
        #expect(editor.kinds == [.bulletItem, .bulletItem, .bulletItem, .paragraph])
        #expect(editor.document.blocks[1].id == childId)
        #expect(editor.textView.selectedRange() == NSRange(location: editor.textLocation(ofBlock: 2) + 1, length: 0))

        editor.undo()
        #expect(editor.texts == ["a", "b", "c"])
        #expect(editor.indents == [0, 1, 0])
    }

    @Test("В свёрнутый переключатель: строки встают после его спрятанных детей")
    func collapsedToggleKeepsHiddenChildren() throws {
        let editor = try EditorFixture([Spec(kind: .toggle, text: "Раздел"), Spec(kind: .paragraph, text: "внутри", indent: 1), .paragraph("после")])
        editor.textView.blockViewState = BlockViewStateStore(database: editor.store.database)
        editor.textView.setCollapsed(true, ofBlock: editor.document.blocks[0].id)
        editor.textView.pastedTextReader = Self.plainLines
        editor.placeCaret(inBlock: 0, at: nil)

        editor.step { editor.textView.paste(from: Self.pasteboard("x\ny")) }

        #expect(editor.texts == ["Разделx", "внутри", "y", "после"])
        #expect(editor.indents == [0, 1, 0, 0])
    }
}
