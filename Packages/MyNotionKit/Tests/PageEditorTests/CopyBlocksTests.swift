import AppKit
import Foundation
import Testing
@testable import NotesCore
@testable import PageEditor

/// Копирование нескольких блоков внутри MyNotion, как в Notion: вставка возвращает виды блоков, вложенность,
/// оформление в строке, ссылки и упоминания; другим программам — Markdown и HTML.
@MainActor
@Suite("Копирование блоков")
struct CopyBlocksTests {
    private static let link = URL(string: "https://example.com/doc")!
    private static let mentioned = UUID()

    /// Заголовок, вложенный список с жирным, задачи, ссылка и упоминание, внизу — пустой абзац для вставки.
    private static func page() throws -> EditorFixture {
        try EditorFixture([
            .heading(2, "План"),
            EditorFixture.Spec(kind: .bulletItem, text: "первый пункт", runs: [StyledRun(start: 0, length: 6, style: .bold)]),
            .bullet("вложенный", indent: 1),
            .checkbox("сделано", checked: true),
            .checkbox("потом"),
            EditorFixture.Spec(kind: .paragraph, text: "Ссылка и \u{FFFC}",
                               runs: [StyledRun(start: 0, length: 6, style: .link(link)), StyledRun(start: 9, length: 1, style: .mention(mentioned))]),
            .paragraph(),
        ])
    }

    private static func board() -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("CopyBlocksTests-\(UUID().uuidString)"))
        board.clearContents()
        return board
    }

    private static func copy(_ editor: EditorFixture) -> NSPasteboard {
        let board = board()
        _ = editor.textView.writeSelection(to: board, types: editor.textView.writablePasteboardTypes)
        return board
    }

    /// Выделить текст от `start` в блоке `first` до `end` в блоке `last` (`nil` — до конца блока).
    private static func select(_ editor: EditorFixture, from first: Int, _ start: Int, to last: Int, _ end: Int?) {
        let lower = editor.textLocation(ofBlock: first) + start
        let upper = editor.textLocation(ofBlock: last) + (end ?? (editor.document.blocks[last].text.string as NSString).length)
        editor.textView.setSelectedRange(NSRange(location: lower, length: upper - lower))
    }

    @Test("Блоки скопированы и вставлены ниже: те же виды, вложенность, отметки, жирный, ссылка и упоминание; одна ⌘Z")
    func copyAndPasteBlocks() throws {
        let editor = try Self.page()
        let copiedIds = editor.document.blocks[0..<6].map(\.id)
        editor.textView.selectBlocks(0..<6)
        let board = Self.copy(editor)
        editor.placeCaret(inBlock: 6)

        editor.step { editor.textView.paste(from: board) }

        let kinds: [BlockKind] = [.heading2, .bulletItem, .bulletItem, .checkbox, .checkbox, .paragraph]
        #expect(editor.kinds == kinds + kinds, "Пустой абзац под курсором стал заголовком, хвоста нет")
        #expect(Array(editor.texts[6..<12]) == ["План", "первый пункт", "вложенный", "сделано", "потом", "Ссылка и \u{FFFC}"])
        #expect(Array(editor.indents[6..<12]) == [0, 0, 1, 0, 0, 0])
        #expect(editor.document.blocks[6..<12].map(\.isChecked) == [false, false, false, true, false, false])
        #expect(editor.document.blocks[7].text.runs == [StyledRun(start: 0, length: 6, style: .bold)])
        #expect(editor.document.blocks[11].text.runs == [StyledRun(start: 0, length: 6, style: .link(Self.link)),
                                                         StyledRun(start: 9, length: 1, style: .mention(Self.mentioned))])
        let pasted = editor.document.blocks[6..<12]
        #expect(Set(pasted.map(\.id)).isDisjoint(with: copiedIds), "У копий — новые id")
        #expect(pasted.allSatisfy { $0.pageId == editor.pageId })

        editor.undo()
        #expect(editor.kinds == kinds + [.paragraph])
    }

    @Test("Часть первого и последнего блока: копируется выделенный кусок, виды блоков остаются")
    func partialSelection() throws {
        let editor = try Self.page()
        // «ан» заголовка — «первый» пункта.
        Self.select(editor, from: 0, 2, to: 1, 6)
        let board = Self.copy(editor)
        editor.placeCaret(inBlock: 6)

        editor.step { editor.textView.paste(from: board) }

        #expect(Array(editor.kinds[6...]) == [.heading2, .bulletItem])
        #expect(Array(editor.texts[6...]) == ["ан", "первый"])
        #expect(editor.document.blocks[7].text.runs == [StyledRun(start: 0, length: 6, style: .bold)])
    }

    @Test("Вложенный пункт с родителем вставляется в пункт глубже: отступы — от места вставки")
    func nestedListIntoNestedItem() throws {
        let editor = try EditorFixture([.bullet("родитель"), .bullet("ребёнок", indent: 1), .bullet("", indent: 2)])
        editor.textView.selectBlocks(0..<2)
        let board = Self.copy(editor)
        editor.placeCaret(inBlock: 2)

        editor.step { editor.textView.paste(from: board) }

        #expect(editor.texts == ["родитель", "ребёнок", "родитель", "ребёнок"])
        #expect(editor.indents == [0, 1, 2, 3])
    }

    @Test("⌘X: блоки уходят со страницы, вставка возвращает их с видами")
    func cutAndPaste() throws {
        let editor = try Self.page()
        Self.select(editor, from: 1, 0, to: 4, nil)
        let board = Self.board()

        editor.step { editor.textView.cut(nil) }
        #expect(editor.texts == ["План", "", "Ссылка и \u{FFFC}", ""], "Вырезанное ушло, первый блок остался пустым")
        let general = NSPasteboard.general
        for type in general.types ?? [] {
            if let data = general.data(forType: type) { board.setData(data, forType: type) }
        }
        editor.placeCaret(inBlock: 1)

        editor.step { editor.textView.paste(from: board) }

        #expect(editor.kinds == [.heading2, .bulletItem, .bulletItem, .checkbox, .checkbox, .paragraph, .paragraph])
        #expect(editor.texts == ["План", "первый пункт", "вложенный", "сделано", "потом", "Ссылка и \u{FFFC}", ""])
        #expect(editor.indents == [0, 0, 1, 0, 0, 0, 0])
        #expect(editor.document.blocks[3].isChecked)
    }

    @Test("На другую страницу: блоки встают в её поток со своей страницей")
    func pasteIntoAnotherPage() throws {
        let source = try Self.page()
        source.textView.selectBlocks(1..<5)
        let board = Self.copy(source)
        let target = try EditorFixture([.paragraph()])

        target.step { target.textView.paste(from: board) }

        #expect(target.kinds == [.bulletItem, .bulletItem, .checkbox, .checkbox])
        #expect(target.indents == [0, 1, 0, 0])
        #expect(target.document.blocks.allSatisfy { $0.pageId == target.pageId })
        let saved = try target.savedBlocks()
        #expect(saved.map(\.kind) == [.bulletItem, .bulletItem, .checkbox, .checkbox])
    }

    @Test("Другим программам: Markdown простым текстом и HTML от писателя приложения; упоминание — названием")
    func markdownAndHTMLForOtherApps() throws {
        let editor = try Self.page()
        var received: [Block] = []
        var titles: [String?] = []
        editor.textView.copiedBlocksWriter = { blocks, pageTitle in
            received = blocks
            titles = [pageTitle(Self.mentioned)]
            return ("markdown", "<p>html</p>")
        }
        editor.textView.selectBlocks(0..<6)
        let board = Self.copy(editor)

        #expect(board.string(forType: .string) == "markdown")
        #expect(board.string(forType: .html) == "<p>html</p>")
        #expect(received.map(\.kind) == [.heading2, .bulletItem, .bulletItem, .checkbox, .checkbox, .paragraph])
        #expect(titles == [nil], "Страницы нет в каталоге упоминаний")
    }

    @Test("Часть одного блока — как раньше: без своего типа блоков и без HTML")
    func singleBlockKeepsInlineCopy() throws {
        let editor = try Self.page()
        editor.textView.copiedBlocksWriter = { _, _ in ("markdown", "<p>html</p>") }
        editor.select(inBlock: 1, "первый")
        let board = Self.copy(editor)

        #expect(board.data(forType: PageTextView.blocksPasteboardType) == nil)
        #expect(board.data(forType: .html) == nil)
        #expect(board.string(forType: .string) == "первый")
        #expect(board.data(forType: PageTextView.inlineTextPasteboardType) != nil)
    }

    @Test("Подстраница копируется упоминанием: у страницы одно место")
    func subpageBecomesMention() throws {
        let child = UUID()
        let editor = try EditorFixture([.paragraph("до"), EditorFixture.Spec(kind: .pageLink, link: child), .paragraph()])
        editor.textView.selectBlocks(0..<2)
        let board = Self.copy(editor)
        editor.placeCaret(inBlock: 2)

        editor.step { editor.textView.paste(from: board) }

        try #require(editor.kinds == [.paragraph, .pageLink, .paragraph, .paragraph], "\(editor.kinds) \(editor.texts)")
        #expect(editor.document.blocks[3].text.runs == [StyledRun(start: 0, length: 1, style: .mention(child))])
    }

    @Test("Копия перенесённого раньше блока — новый блок: пометки «Переместить в» нет, восстановление версии её не тронет")
    func pasteDropsMovedFromMark() throws {
        var props = BlockProps()
        props.movedFrom = UUID()
        let editor = try EditorFixture([.paragraph("до"), EditorFixture.Spec(kind: .paragraph, text: "перенесён", props: props), .paragraph()])
        editor.textView.selectBlocks(0..<2)
        let board = Self.copy(editor)
        editor.placeCaret(inBlock: 2)

        editor.step { editor.textView.paste(from: board) }

        try #require(editor.texts == ["до", "перенесён", "до", "перенесён"])
        #expect(editor.document.blocks[3].props.movedFrom == nil)
        #expect(try editor.savedBlocks().filter { $0.props.movedFrom != nil }.count == 1, "Пометка — только у самого перенесённого")
    }

    @Test("Таблица вставляется с содержимым ячеек: ячейки — на копиях своих столбцов")
    func pasteTableKeepsCells() throws {
        let source = try EditorFixture([.paragraph("до"), EditorFixture.Spec(kind: .table), .paragraph()])
        let table = source.document.blocks[1]
        try source.store.write { tx in
            for block in TableGrid.contents(ofTable: table, cells: [[InlineText("а"), InlineText("б")], [InlineText("в"), InlineText("г")]]) {
                try tx.insertBlock(block)
            }
        }
        let editor = try EditorFixture(reopening: source)
        editor.textView.selectBlocks(0..<2)
        let board = Self.copy(editor)
        editor.placeCaret(inBlock: 2)

        editor.step { editor.textView.paste(from: board) }

        let pasted = try #require(editor.document.blocks.last { $0.kind == .table && $0.id != table.id })
        let grid = try #require(editor.document.tableGrid(pasted.id))
        #expect((0..<grid.rowCount).map { row in (0..<grid.columnCount).map { grid.text(row: row, column: $0).string } } == [["а", "б"], ["в", "г"]])
    }

    @Test("Выполненная задача в пустую задачу: отметка, цвет и свойства — от копии")
    func checkedTaskIntoEmptyTask() throws {
        var props = BlockProps()
        props.values["custom"] = .string("копия")
        let editor = try EditorFixture([EditorFixture.Spec(kind: .checkbox, text: "сделано", checked: true, props: props,
                                                           color: BlockColor(text: .red)),
                                        .checkbox("")])
        editor.textView.selectBlocks(0..<1)
        let board = Self.copy(editor)
        editor.placeCaret(inBlock: 1)

        editor.step { editor.textView.paste(from: board) }

        try #require(editor.texts == ["сделано", "сделано"])
        let pasted = editor.document.blocks[1]
        #expect(pasted.isChecked)
        #expect(pasted.color == BlockColor(text: .red))
        #expect(pasted.props.values["custom"] == .string("копия"))
    }
}
