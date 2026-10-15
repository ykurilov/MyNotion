import AppKit
import Foundation
import Testing
@testable import NotesCore
@testable import PageEditor

/// Вложенность, перестановка, чекбоксы, смена типа и их отмена (FR-008, FR-011, FR-012).
@MainActor
@Suite("Вложенность и перестановка блоков")
struct BlockStructureTests {
    // MARK: Вложенность

    @Test("Tab вкладывает пункт не глубже соседа сверху + 1, ⇧Tab вынимает")
    func tabIndentsWithinPreviousLevel() throws {
        let editor = try EditorFixture([.bullet("один"), .bullet("два"), .checkbox("три")])
        editor.placeCaret(inBlock: 1, at: 2)

        editor.press(#selector(NSResponder.insertTab(_:)))
        editor.press(#selector(NSResponder.insertTab(_:)))
        #expect(editor.indents == [0, 1, 0], "Глубже соседа сверху + 1 не вкладывается")

        editor.placeCaret(inBlock: 2)
        editor.press(#selector(NSResponder.insertTab(_:)))
        editor.press(#selector(NSResponder.insertTab(_:)))
        #expect(editor.indents == [0, 1, 2])

        editor.press(#selector(NSResponder.insertBacktab(_:)))
        #expect(editor.indents == [0, 1, 1])
        #expect(editor.texts == ["один", "два", "три"], "Tab не вставляет символ табуляции")
    }

    @Test("Вложенность в пределах 0…8")
    func indentStaysWithinRange() throws {
        let editor = try EditorFixture((0...8).map { .bullet("пункт \($0)", indent: $0) } + [.bullet("последний", indent: 8)])
        editor.placeCaret(inBlock: 9)
        editor.press(#selector(NSResponder.insertTab(_:)))
        #expect(editor.indents.last == 8)

        editor.placeCaret(inBlock: 0)
        editor.press(#selector(NSResponder.insertBacktab(_:)))
        #expect(editor.indents.first == 0)
        editor.press(#selector(NSResponder.insertTab(_:)))
        #expect(editor.indents.first == 0, "Первому блоку не во что вкладываться")
    }

    @Test("Заголовок всегда на уровне 0")
    func headingNeverIndents() throws {
        let editor = try EditorFixture([.bullet("пункт"), .heading(2, "Заголовок")])
        editor.placeCaret(inBlock: 1)

        editor.press(#selector(NSResponder.insertTab(_:)))

        #expect(editor.indents == [0, 0])
        #expect(editor.texts == ["пункт", "Заголовок"])
    }

    @Test("Tab с выделением через несколько пунктов вкладывает все")
    func tabIndentsSelectedBlocks() throws {
        let editor = try EditorFixture([.bullet("а"), .bullet("бб"), .bullet("вв")])
        let start = editor.textLocation(ofBlock: 1)
        editor.textView.setSelectedRange(NSRange(location: start + 1, length: 3))

        editor.press(#selector(NSResponder.insertTab(_:)))

        #expect(editor.indents == [0, 1, 1])
        #expect(editor.textView.selectedRange() == NSRange(location: start + 1, length: 3), "Выделение на месте")
    }

    // MARK: Перестановка

    @Test("⌥⇧↑ и ⌥⇧↓ переставляют блок и меняют только его sortKey")
    func moveUpAndDown() throws {
        let editor = try EditorFixture([.paragraph("А"), .heading(1, "Б"), .bullet("В")])
        let original = editor.document.blocks
        editor.placeCaret(inBlock: 2, at: 1)

        editor.perform(.moveBlocksUp)

        #expect(editor.texts == ["А", "В", "Б"])
        #expect(editor.kinds == [.paragraph, .bulletItem, .heading1])
        let moved = editor.document.blocks[1]
        #expect(moved.id == original[2].id && moved.sortKey != original[2].sortKey)
        #expect(editor.document.blocks[0].sortKey == original[0].sortKey && editor.document.blocks[2].sortKey == original[1].sortKey)
        #expect(editor.document.blocks.map(\.sortKey) == editor.document.blocks.map(\.sortKey).sorted())
        #expect(editor.textView.string == "А\nВ\nБ\n")
        #expect(editor.textView.selectedRange() == NSRange(location: 3, length: 0), "Курсор едет вместе с блоком")

        editor.perform(.moveBlocksUp)
        editor.perform(.moveBlocksUp)
        #expect(editor.texts == ["В", "А", "Б"], "Выше первого места блок не уходит")

        editor.perform(.moveBlocksDown)
        editor.perform(.moveBlocksDown)
        editor.perform(.moveBlocksDown)
        #expect(editor.texts == ["А", "Б", "В"])
    }

    @Test("Перестановка сохраняется в базе")
    func moveIsSaved() throws {
        let editor = try EditorFixture([.paragraph("А"), .paragraph("Б"), .paragraph("В")])
        editor.placeCaret(inBlock: 0)
        editor.perform(.moveBlocksDown)

        let saved = try editor.savedBlocks()

        #expect(saved.map(\.text.string) == ["Б", "А", "В"])
    }

    @Test("Перетаскивание блока за «⋮⋮» на новое место")
    func dragMovesBlock() throws {
        let editor = try EditorFixture([.paragraph("А"), .paragraph("Б"), .paragraph("В"), .paragraph("Г")])
        let id = editor.document.blocks[0].id

        editor.step { editor.textView.moveBlock(id, toGap: 3) }
        #expect(editor.texts == ["Б", "В", "А", "Г"])

        editor.step { editor.textView.moveBlock(editor.document.blocks[3].id, toGap: 0) }
        #expect(editor.texts == ["Г", "Б", "В", "А"])

        editor.undo()
        editor.undo()
        #expect(editor.texts == ["А", "Б", "В", "Г"])
        #expect(editor.textView.string == "А\nБ\nВ\nГ\n")
    }

    /// А с двумя вложенными, Б с одним вложенным, В.
    static let nestedPage: [EditorFixture.Spec] = [
        .bullet("А"), .bullet("а1", indent: 1), .bullet("а2", indent: 1), .bullet("Б"), .bullet("б1", indent: 1), .paragraph("В"),
    ]

    @Test("⌥⇧↓ и ⌥⇧↑ переносят пункт вместе с вложенными, через соседа с его вложенными")
    func moveCarriesNestedItems() throws {
        let editor = try EditorFixture(Self.nestedPage)
        editor.placeCaret(inBlock: 0)

        editor.perform(.moveBlocksDown)
        #expect(editor.texts == ["Б", "б1", "А", "а1", "а2", "В"])
        #expect(editor.indents == [0, 1, 0, 1, 1, 0], "Вложенность едет вместе с пунктом")
        #expect(editor.document.blocks.map(\.sortKey) == editor.document.blocks.map(\.sortKey).sorted())
        #expect(editor.textView.selectedRange().location == editor.textLocation(ofBlock: 2), "Курсор едет вместе с пунктом")

        editor.perform(.moveBlocksUp)
        #expect(editor.texts == ["А", "а1", "а2", "Б", "б1", "В"])

        editor.undo()
        #expect(editor.texts == ["Б", "б1", "А", "а1", "а2", "В"])
        editor.undo()
        #expect(editor.texts == ["А", "а1", "а2", "Б", "б1", "В"])

        let saved = try editor.savedBlocks()
        #expect(saved.map(\.text.string) == ["А", "а1", "а2", "Б", "б1", "В"])
    }

    @Test("Вложенный пункт переставляется среди своих соседей")
    func nestedItemMovesAmongSiblings() throws {
        let editor = try EditorFixture(Self.nestedPage)
        editor.placeCaret(inBlock: 2)

        editor.perform(.moveBlocksUp)
        #expect(editor.texts == ["А", "а2", "а1", "Б", "б1", "В"])
        #expect(editor.indents == [0, 1, 1, 0, 1, 0])
    }

    @Test("Перетаскивание за «⋮⋮» переносит пункт вместе с вложенными")
    func dragCarriesNestedItems() throws {
        let editor = try EditorFixture(Self.nestedPage)
        let parent = editor.document.blocks[0].id

        editor.step { editor.textView.moveBlock(parent, toGap: 5) }
        #expect(editor.texts == ["Б", "б1", "А", "а1", "а2", "В"])
        #expect(editor.indents == [0, 1, 0, 1, 1, 0])

        editor.step { editor.textView.moveBlock(parent, toGap: 0) }
        #expect(editor.texts == ["А", "а1", "а2", "Б", "б1", "В"])

        editor.step { editor.textView.moveBlock(parent, toGap: 2) }
        #expect(editor.texts == ["А", "а1", "а2", "Б", "б1", "В"], "В свои же вложенные пункт не переносится")

        let child = editor.document.blocks[4].id
        editor.step { editor.textView.moveBlock(child, toGap: 6) }
        #expect(editor.texts == ["А", "а1", "а2", "Б", "В", "б1"], "Вложенный пункт без своих вложенных едет один")

        editor.undo()
        editor.undo() // шаг без перестановки
        editor.undo()
        #expect(editor.texts == ["Б", "б1", "А", "а1", "а2", "В"])
        #expect(editor.textView.string == "Б\nб1\nА\nа1\nа2\nВ\n")
    }

    @Test("Место сброса при перетаскивании: зазор ближе к середине блока")
    func dropGapFollowsPointer() {
        let frames: [ClosedRange<CGFloat>] = [0...30, 30...60, 60...90]
        #expect(BlockMoveController.gap(forPointerY: 5, blockFrames: frames) == 0)
        #expect(BlockMoveController.gap(forPointerY: 20, blockFrames: frames) == 1)
        #expect(BlockMoveController.gap(forPointerY: 44, blockFrames: frames) == 1)
        #expect(BlockMoveController.gap(forPointerY: 46, blockFrames: frames) == 2)
        #expect(BlockMoveController.gap(forPointerY: 500, blockFrames: frames) == 3)
    }

    // MARK: Чекбокс

    @Test("⌘Enter ставит и снимает отметку чекбокса, у других блоков ничего не делает")
    func commandEnterTogglesCheckbox() throws {
        let editor = try EditorFixture([.checkbox("дело"), .paragraph("текст")])
        editor.placeCaret(inBlock: 0, at: 2)

        editor.perform(.toggleChecked)
        #expect(editor.document.blocks[0].isChecked)
        #expect(editor.texts == ["дело", "текст"])
        editor.perform(.toggleChecked)
        #expect(!editor.document.blocks[0].isChecked)

        editor.placeCaret(inBlock: 1)
        editor.perform(.toggleChecked)
        #expect(editor.kinds == [.checkbox, .paragraph] && !editor.document.blocks[1].isChecked)
    }

    @Test("⌘Enter приходит с клавиатуры")
    func commandEnterBinding() {
        #expect(EditorKeyBindings.command(characters: "\r", modifiers: .command) == .toggleChecked)
        #expect(EditorKeyBindings.command(characters: "\r", modifiers: []) == nil)
    }

    @Test("Щелчок по квадрату чекбокса переключает отметку, щелчок по тексту — нет")
    func clickOnCheckboxSquare() throws {
        let editor = try EditorFixture([.paragraph("абзац"), .checkbox("дело")])
        let id = editor.document.blocks[1].id
        let square = try #require(editor.textView.checkboxRect(ofBlock: id))
        #expect(square.width == 16 && square.height == 16)

        #expect(editor.textView.checkbox(at: NSPoint(x: square.midX, y: square.midY)) == id)
        #expect(editor.textView.checkbox(at: NSPoint(x: square.maxX + 40, y: square.midY)) == nil)
        editor.step { editor.textView.toggleCheckbox(ofBlock: id) }

        #expect(editor.document.blocks[1].isChecked)
        #expect(try editor.savedBlocks()[1].isChecked)
    }

    // MARK: Смена типа

    @Test("Смена типа блока из меню сохраняет текст")
    func changeKindKeepsText() throws {
        let editor = try EditorFixture([.bullet("пункт", indent: 1), .paragraph("ниже")])
        editor.placeCaret(inBlock: 0, at: 3)

        editor.perform(.setKind(.heading2))

        #expect(editor.kinds == [.heading2, .paragraph])
        #expect(editor.indents == [0, 0], "У заголовка вложенности нет")
        #expect(editor.texts == ["пункт", "ниже"])
    }

    // MARK: Отмена

    @Test("⌘Z и ⇧⌘Z для смены типа, вложенности, перестановки и набора — одной цепочкой")
    func undoRedoStructuralChanges() throws {
        let editor = try EditorFixture([.paragraph("А"), .bullet("Б"), .bullet("В")])
        let original = editor.document.blocks.map { BlockDraft($0) }

        editor.placeCaret(inBlock: 2, at: 1)
        editor.type("!")
        editor.press(#selector(NSResponder.insertTab(_:)))
        editor.perform(.setKind(.checkbox))
        editor.perform(.toggleChecked)
        editor.perform(.moveBlocksUp)
        #expect(editor.texts == ["А", "В!", "Б"])
        #expect(editor.kinds == [.paragraph, .checkbox, .bulletItem])
        let changed = editor.document.blocks.map { BlockDraft($0) }

        for _ in 0..<5 { editor.undo() }
        #expect(editor.document.blocks.map { BlockDraft($0) } == original)
        #expect(editor.textView.string == "А\nБ\nВ\n")

        for _ in 0..<5 { editor.redo() }
        #expect(editor.document.blocks.map { BlockDraft($0) } == changed)
        #expect(editor.textView.string == "А\nВ!\nБ\n")
    }

    @Test("Отмена смены типа пустого последнего блока")
    func undoKindOfTrailingEmptyBlock() throws {
        let editor = try EditorFixture([.paragraph("текст"), .paragraph()])
        editor.placeCaret(inBlock: 1)

        editor.perform(.setKind(.checkbox))
        #expect(editor.kinds == [.paragraph, .checkbox])
        editor.undo()
        #expect(editor.kinds == [.paragraph, .paragraph])
        #expect(editor.textView.string == "текст\n\n")
    }
}
