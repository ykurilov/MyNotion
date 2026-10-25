import AppKit
import Foundation
import Testing
@testable import NotesCore
@testable import PageEditor

/// Вставка текста другой программы блоками (Markdown ответа ИИ): разбор подменён, проверяется, как блоки встают на страницу.
@MainActor
@Suite("Вставка блоками")
struct PasteBlocksTests {
    /// Разбор, который на текст «markdown» отвечает этими блоками, а на прочий — «вставлять текстом».
    private static func reader(_ blocks: [Block]) -> PageTextView.PastedTextReader {
        { text, _, _, _ in text == "markdown" ? blocks : nil }
    }

    private static func block(_ kind: BlockKind, _ text: String = "", indent: Int = 0, runs: [StyledRun] = []) -> Block {
        Block(pageId: UUID(), kind: kind, text: InlineText(text, runs: runs), indent: indent, sortKey: .between(nil, nil))
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
        editor.textView.pastedTextReader = { _, _, _, _ in
            asked = true
            return [Self.block(.heading1, "не должно")]
        }
        editor.placeCaret(inBlock: 0)

        editor.step { editor.textView.paste(from: Self.pasteboard("## Заголовок\n**жирный**"), asPlainText: true) }

        #expect(!asked)
        #expect(editor.kinds.allSatisfy { $0 == .paragraph })
        #expect(editor.texts == ["## Заголовок", "**жирный**"])
    }
}
