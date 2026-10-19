import AppKit
import Testing
@testable import NotesCore
@testable import PageEditor

/// Колонки в редакторе (contracts/blocks-and-keys.md, «Колонки»; research R3): у каждой колонки свой редактор потока
/// (`FlowTextView`) с общей отменой окна; перетаскивание «⋮⋮» к правому краю блока собирает колонки, курсор ходит
/// между колонками и блоками над и под ними.
@MainActor
@Suite("Колонки в редакторе")
struct ColumnsTests {
    typealias Spec = EditorFixture.Spec

    /// Поток страницы и колонки текстами: «[A|B]».
    func describe(_ document: PageDocument) -> [String] {
        document.blocks.map { block in
            guard block.kind == .columnList else { return block.text.string }
            return "[" + document.flow(block.id).map { column in
                document.flow(column.id).map(\.text.string).joined(separator: " ")
            }.joined(separator: "|") + "]"
        }
    }

    /// Страница «P1, [L1 L2 | R1], P2» с видом колонок на экране.
    func columnsFixture() throws -> (editor: EditorFixture, list: UUID) {
        let editor = try EditorFixture([.paragraph("P1"), .paragraph("L1"), .paragraph("L2"), .paragraph("R1"), .paragraph("P2")])
        let ids = editor.document.blocks.map(\.id)
        editor.step { editor.textView.placeBlocks([ids[3]], besideRightOf: ids[1]) }
        let list = try #require(editor.document.blocks.first { $0.kind == .columnList }).id
        editor.step { editor.textView.moveBlocks([ids[2]], to: editor.document.flow(list)[0].id, after: ids[1], before: nil) }
        #expect(describe(editor.document) == ["P1", "[L1 L2|R1]", "P2"])
        editor.layoutViewport()
        return (editor, list)
    }

    func columnEditors(_ editor: EditorFixture, _ list: UUID) throws -> [FlowTextView] {
        let editors = editor.textView.flowEditors(inColumnList: list)
        #expect(editors.count == 2)
        return editors
    }

    // MARK: Сборка

    @Test("«⋮⋮» к правому краю блока — две колонки (цель слева); всё одним шагом ⌘Z")
    func dragToRightEdge() throws {
        let editor = try EditorFixture([.paragraph("A"), .paragraph("B"), .paragraph("C")])
        let (a, b) = (editor.document.blocks[0].id, editor.document.blocks[1].id)
        let frame = try #require(editor.textView.frameInWindow(ofBlock: a))
        let point = NSPoint(x: frame.maxX - 8, y: frame.midY)
        #expect(editor.textView.dropTarget(forBlock: b, atWindowPoint: point) == .besideRight(a))
        // Посередине блока — обычное место между блоками, не колонки.
        if case .besideRight? = editor.textView.dropTarget(forBlock: b, atWindowPoint: NSPoint(x: frame.minX + 40, y: frame.midY)) {
            Issue.record("посередине блока — не колонки")
        }
        editor.step { _ = editor.textView.dropBlock(b, atWindowPoint: point) }
        #expect(describe(editor.document) == ["[A|B]", "C"])
        #expect(editor.textView.string == "\u{FFFC}\nC\n", "колонки — один знак-вложение в тексте страницы")

        editor.undo()
        #expect(describe(editor.document) == ["A", "B", "C"])
        #expect(editor.document.blocks.map(\.id).prefix(2) == [a, b], "⌘Z возвращает те же блоки")
        editor.redo()
        #expect(describe(editor.document) == ["[A|B]", "C"])
        let saved = try editor.savedBlocks()
        #expect(saved.filter { $0.kind == .column }.count == 2)
    }

    @Test("К краю колонки — ещё колонка, до пяти; шестой нет")
    func upToFiveColumns() throws {
        let editor = try EditorFixture((1...6).map { .paragraph("\($0)") })
        let ids = editor.document.blocks.map(\.id)
        for index in 1...4 {
            editor.step { editor.textView.placeBlocks([ids[index]], besideRightOf: ids[index - 1]) }
        }
        #expect(describe(editor.document) == ["[1|2|3|4|5]", "6"])
        editor.layoutViewport()
        let fifth = try #require(editor.textView.frameInWindow(ofBlock: ids[4]))
        #expect(editor.textView.dropTarget(forBlock: ids[5], atWindowPoint: NSPoint(x: fifth.maxX - 4, y: fifth.midY)) != .besideRight(ids[4]))
    }

    @Test("«/» → «Колонки: 3» — три пустые колонки, курсор в первой")
    func slashColumns() throws {
        let editor = try EditorFixture([.paragraph("до")])
        editor.placeCaret(inBlock: 0, at: nil)
        editor.press(#selector(NSResponder.insertNewline(_:)))
        editor.type("/колонки 3")
        #expect(editor.textView.popups.visibleItems.map(\.action) == [.insertColumns(3)])
        editor.press(#selector(NSResponder.insertNewline(_:)))
        let list = try #require(editor.document.blocks.first { $0.kind == .columnList })
        #expect(describe(editor.document) == ["до", "[||]", ""])
        let columns = editor.document.flow(list.id)
        #expect(columns.count == 3 && columns.allSatisfy { editor.document.flow($0.id).count == 1 })
        let focused = try #require(editor.window.firstResponder as? FlowTextView)
        #expect(focused.document.containerId == columns[0].id)
        editor.undo()
        #expect(describe(editor.document) == ["до", "/колонки 3"] || describe(editor.document) == ["до", ""])
    }

    // MARK: Правка внутри колонки

    @Test("Набор в колонке — в её поток; ⌘Z общий с окном; после записи и открытия заново — на месте")
    func typingInColumn() throws {
        let (editor, list) = try columnsFixture()
        let editors = try columnEditors(editor, list)
        let left = editors[0]
        #expect(left.string == "L1\nL2\n")
        editor.window.makeFirstResponder(left)
        left.setSelectedRange(NSRange(location: 2, length: 0))
        editor.step { left.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0)) }
        #expect(describe(editor.document) == ["P1", "[L1! L2|R1]", "P2"])
        #expect(editor.textView.string == "P1\n\u{FFFC}\nP2\n", "текст страницы не меняется")
        editor.undo()
        #expect(describe(editor.document) == ["P1", "[L1 L2|R1]", "P2"])
        editor.redo()
        _ = try editor.savedBlocks()
        let reopened = try EditorFixture(reopening: editor)
        #expect(describe(reopened.document) == ["P1", "[L1! L2|R1]", "P2"])
    }

    @Test("Enter в колонке — новый блок колонки; ⌫ в начале склеивает внутри колонки")
    func enterAndBackspaceInColumn() throws {
        let (editor, list) = try columnsFixture()
        let right = try columnEditors(editor, list)[1]
        editor.window.makeFirstResponder(right)
        right.setSelectedRange(NSRange(location: 2, length: 0))
        editor.step { right.insertNewline(nil) }
        editor.step { right.insertText("R2", replacementRange: NSRange(location: NSNotFound, length: 0)) }
        #expect(describe(editor.document) == ["P1", "[L1 L2|R1 R2]", "P2"])
        editor.step { right.setSelectedRange(NSRange(location: 3, length: 0)) }
        editor.step { right.deleteBackward(nil) }
        #expect(describe(editor.document) == ["P1", "[L1 L2|R1R2]", "P2"])
    }

    // MARK: Распад

    @Test("Последний блок унесли из колонки — колонка исчезает, одна осталась — колонки распадаются; одним шагом ⌘Z")
    func emptyColumnDissolves() throws {
        let (editor, list) = try columnsFixture()
        let r1 = try #require(editor.document.flow(editor.document.flow(list)[1].id).first).id
        let p2 = try #require(editor.textView.frameInWindow(ofBlock: editor.document.blocks[2].id))
        // Ниже P2 — в конец страницы.
        let point = NSPoint(x: p2.minX + 40, y: p2.minY - 4)
        editor.step { _ = editor.textView.dropBlock(r1, atWindowPoint: point) }
        #expect(describe(editor.document) == ["P1", "L1", "L2", "P2", "R1"])
        #expect(editor.textView.string == "P1\nL1\nL2\nP2\nR1\n")
        editor.undo()
        #expect(describe(editor.document) == ["P1", "[L1 L2|R1]", "P2"])
    }

    @Test("Блок страницы — в колонку перетаскиванием на место между её блоками")
    func dragIntoColumn() throws {
        let (editor, list) = try columnsFixture()
        let p1 = editor.document.blocks[0].id
        let l2 = try #require(editor.textView.frameInWindow(ofBlock: editor.document.flow(editor.document.flow(list)[0].id)[1].id))
        editor.step { _ = editor.textView.dropBlock(p1, atWindowPoint: NSPoint(x: l2.minX + 20, y: l2.minY + 2)) }
        #expect(describe(editor.document) == ["[L1 L2 P1|R1]", "P2"])
        editor.undo()
        #expect(describe(editor.document) == ["P1", "[L1 L2|R1]", "P2"])
    }

    // MARK: Ширина

    @Test("Граница колонок тянется: доли 10–90 %, одним шагом ⌘Z")
    func dividerDrag() throws {
        let (editor, list) = try columnsFixture()
        let view = try #require(editor.textView.columnsView(for: list))
        editor.step { view.dragDivider(0, toFraction: 0.02) }
        #expect(ColumnLayout.ratios(of: editor.document.flow(list)) == [0.1, 0.9])
        let editors = try columnEditors(editor, list)
        #expect(editors[0].frame.width < editors[1].frame.width / 5)
        editor.undo()
        #expect(ColumnLayout.ratios(of: editor.document.flow(list)) == [0.5, 0.5])
    }

    // MARK: Курсор между потоками

    @Test("↓ со строки над колонками — в первую колонку; ↑ с её первой строки — назад")
    func arrowsIntoAndOutOfColumns() throws {
        let (editor, list) = try columnsFixture()
        let editors = try columnEditors(editor, list)
        editor.placeCaret(inBlock: 0, at: 1)
        editor.press(#selector(NSResponder.moveDown(_:)))
        #expect(editor.window.firstResponder === editors[0])
        #expect(editors[0].selectedRange().location == 0)

        editor.step { editors[0].doCommand(by: #selector(NSResponder.moveUp(_:))) }
        #expect(editor.window.firstResponder === editor.textView)
        #expect(editor.textView.selectedRange().location == 2, "в конец блока над колонками")
    }

    @Test("→ в конце колонки — в начало следующей; ← в начале — в конец предыдущей")
    func arrowsBetweenColumns() throws {
        let (editor, list) = try columnsFixture()
        let editors = try columnEditors(editor, list)
        editor.window.makeFirstResponder(editors[0])
        editors[0].setSelectedRange(NSRange(location: 5, length: 0))
        editor.step { editors[0].doCommand(by: #selector(NSResponder.moveRight(_:))) }
        #expect(editor.window.firstResponder === editors[1])
        #expect(editors[1].selectedRange().location == 0)
        editor.step { editors[1].doCommand(by: #selector(NSResponder.moveLeft(_:))) }
        #expect(editor.window.firstResponder === editors[0])
        #expect(editors[0].selectedRange().location == 5)
    }

    @Test("↓ с последней строки колонки — в блок под колонками; ↑ из него — в колонку")
    func arrowsBelowColumns() throws {
        let (editor, list) = try columnsFixture()
        let editors = try columnEditors(editor, list)
        editor.window.makeFirstResponder(editors[1])
        editors[1].setSelectedRange(NSRange(location: 1, length: 0))
        editor.step { editors[1].doCommand(by: #selector(NSResponder.moveDown(_:))) }
        #expect(editor.window.firstResponder === editor.textView)
        #expect(editor.textView.selectedRange().location == editor.textLocation(ofBlock: 2))
        editor.press(#selector(NSResponder.moveUp(_:)))
        #expect(editor.window.firstResponder is FlowTextView)
    }

    @Test("Внутри колонки стрелки ходят по её строкам, как в странице")
    func arrowsInsideColumn() throws {
        let (editor, list) = try columnsFixture()
        let left = try columnEditors(editor, list)[0]
        editor.window.makeFirstResponder(left)
        left.setSelectedRange(NSRange(location: 1, length: 0))
        editor.step { left.doCommand(by: #selector(NSResponder.moveDown(_:))) }
        #expect(editor.window.firstResponder === left)
        #expect(left.selectedRange().location == 4)
    }
}

extension EditorFixture {
    /// Разложить видимую часть страницы: виды блоков-вложений (колонки, таблицы) создаются.
    func layoutViewport() {
        textView.layoutSubtreeIfNeeded()
        textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
        for editor in textView.editorTree {
            editor.layoutEmbeddedViews()
            editor.layoutSubtreeIfNeeded()
        }
    }
}
