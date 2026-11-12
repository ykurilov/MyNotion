import AppKit
import Testing
@testable import NotesCore
@testable import PageEditor

/// Меню «⋮⋮» внутри выделения, как в Notion: щелчок по «⋮⋮» блока внутри выделения (текст через блоки или блоки)
/// выделяет все эти блоки, и действие меню — тип, цвет, удаление — касается их всех. «⋮⋮» вне выделения — только его блок.
@MainActor
@Suite("Меню блока на выделении")
struct BlockMenuSelectionTests {
    private let anchor = NSRect(x: 100, y: 500, width: 20, height: 20)

    private func kindItem(_ kind: BlockKind) throws -> PopupMenuItem {
        try #require(PopupMenuItem.blockKinds.first { $0.action == .setKind(kind) })
    }

    /// Выделить мышью текст от середины блока `first` до середины блока `last`.
    private func selectText(_ editor: EditorFixture, from first: Int, to last: Int) {
        let start = editor.textLocation(ofBlock: first) + 1
        editor.textView.setSelectedRange(NSRange(location: start, length: editor.textLocation(ofBlock: last) + 2 - start))
    }

    private func list() throws -> EditorFixture {
        try EditorFixture([.bullet("один"), .bullet("два", indent: 1), .bullet("три", indent: 1), .bullet("четыре"),
                           .paragraph("после")])
    }

    @Test("Текст выделен через весь список, «⋮⋮» среднего пункта → «Преобразовать в → Чекбокс»: чекбоксами стали все")
    func turnIntoFromHandleInsideTextSelection() throws {
        let editor = try list()
        selectText(editor, from: 0, to: 3)
        editor.textView.selectBlockAndOpenMenu(editor.document.blocks[2].id, below: anchor)
        #expect(editor.textView.selectedBlocks == 0..<4, "Выделение не сбросилось до одного блока")

        let checkbox = try kindItem(.checkbox)
        editor.step { editor.textView.popups.choose(checkbox) }
        #expect(editor.kinds == [.checkbox, .checkbox, .checkbox, .checkbox, .paragraph])
        #expect(editor.indents == [0, 1, 1, 0, 0], "Вложенность пунктов сохранилась")
        #expect(editor.textView.selectedBlocks == 0..<4, "Блоки остались выделенными")
        editor.undo()
        #expect(editor.kinds == [.bulletItem, .bulletItem, .bulletItem, .bulletItem, .paragraph], "Один шаг ⌘Z")
    }

    @Test("Блоки выделены, «⋮⋮» одного из них → «Преобразовать в»: меняется тип всех выделенных")
    func turnIntoFromHandleInsideBlockSelection() throws {
        let editor = try list()
        editor.step { editor.textView.selectBlocks(1..<4) }
        editor.textView.selectBlockAndOpenMenu(editor.document.blocks[3].id, below: anchor)
        #expect(editor.textView.selectedBlocks == 1..<4)

        let checkbox = try kindItem(.checkbox)
        editor.step { editor.textView.popups.choose(checkbox) }
        #expect(editor.kinds == [.bulletItem, .checkbox, .checkbox, .checkbox, .paragraph])
    }

    @Test("«⋮⋮» блока вне выделения: выделен и меняется только он")
    func handleOutsideSelectionTakesOnlyItsBlock() throws {
        let editor = try list()
        selectText(editor, from: 0, to: 1)
        editor.textView.selectBlockAndOpenMenu(editor.document.blocks[3].id, below: anchor)
        #expect(editor.textView.selectedBlocks == 3..<4)

        let checkbox = try kindItem(.checkbox)
        editor.step { editor.textView.popups.choose(checkbox) }
        #expect(editor.kinds == [.bulletItem, .bulletItem, .bulletItem, .checkbox, .paragraph])
    }

    @Test("«⋮⋮» внутри выделения → «Цвет»: цвет фона у всех выделенных блоков")
    func colorFromHandleInsideSelection() throws {
        let editor = try list()
        selectText(editor, from: 0, to: 3)
        editor.textView.selectBlockAndOpenMenu(editor.document.blocks[1].id, below: anchor)
        editor.step {
            editor.textView.applyColorChoice(ColorChoice(target: .background, color: .yellow), to: .block(editor.document.blocks[1].id))
        }
        #expect(editor.document.blocks.map { $0.color.color(for: .background) } == [.yellow, .yellow, .yellow, .yellow, nil])
    }

    @Test("«⋮⋮» внутри выделения → «Удалить»: удалены все выделенные блоки")
    func deleteFromHandleInsideSelection() throws {
        let editor = try list()
        selectText(editor, from: 1, to: 3)
        editor.textView.selectBlockAndOpenMenu(editor.document.blocks[2].id, below: anchor)
        editor.step { editor.textView.popups.choose(.delete) }
        #expect(editor.texts == ["один", "после"])
    }

    @Test("Текст через несколько пунктов, «⋯» панели → «Преобразовать в → Чекбокс»: чекбоксами стали все")
    func turnIntoFromFormatBarMoreMenu() throws {
        let editor = try list()
        selectText(editor, from: 0, to: 3)
        editor.textView.formatBar.press(.more)
        #expect(editor.textView.popups.isOpen)

        let checkbox = try kindItem(.checkbox)
        editor.step { editor.textView.popups.choose(checkbox) }
        #expect(editor.kinds == [.checkbox, .checkbox, .checkbox, .checkbox, .paragraph])
    }

    @Test("Esc превращает выделенный текст в блоки, ⌥⌘1 — заголовок у всех")
    func shortcutOnBlockSelection() throws {
        let editor = try EditorFixture([.bullet("один"), .bullet("два", indent: 1), .paragraph("после")])
        selectText(editor, from: 0, to: 1)
        editor.press(#selector(NSResponder.cancelOperation(_:)))
        #expect(editor.textView.selectedBlocks == 0..<2)
        editor.perform(.setKind(.heading1))
        #expect(editor.kinds == [.heading1, .heading1, .paragraph])
    }
}
