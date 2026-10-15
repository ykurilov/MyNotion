import AppKit
import Foundation
import Testing
@testable import NotesCore
@testable import PageEditor

/// Быстрые символы и выход из списков (contracts/editor-interactions.md, «Быстрые символы»; FR-009).
@MainActor
@Suite("Быстрые символы")
struct MarkdownShortcutTests {
    @Test("Символы в начале пустой строки и пробел меняют тип блока", arguments: [
        ("#", BlockKind.heading1), ("##", .heading2), ("###", .heading3),
        ("-", .bulletItem), ("*", .bulletItem), ("1.", .numberedItem), ("[]", .checkbox), ("[ ]", .checkbox),
    ])
    func shortcutChangesKind(prefix: String, kind: BlockKind) throws {
        let editor = try EditorFixture([.paragraph("Выше"), .paragraph(), .paragraph("Ниже")])
        editor.placeCaret(inBlock: 1)

        editor.type(prefix + " ")

        #expect(editor.kinds == [.paragraph, kind, .paragraph])
        #expect(editor.texts == ["Выше", "", "Ниже"], "Символы быстрого ввода в текст не попадают")
        #expect(editor.textView.string == "Выше\n\nНиже\n")
    }

    @Test("Быстрый символ в единственном пустом блоке новой страницы")
    func shortcutInEmptyPage() throws {
        let editor = try EditorFixture()
        editor.placeCaret(inBlock: 0)

        editor.type("- ")
        editor.type("пункт")

        #expect(editor.kinds == [.bulletItem])
        #expect(editor.texts == ["пункт"])
    }

    @Test("Пробел не в начале строки — просто пробел")
    func spaceElsewhereIsText() throws {
        let editor = try EditorFixture([.paragraph()])
        editor.placeCaret(inBlock: 0)

        editor.type("a# ")
        editor.type(" #")
        editor.type(" ")

        #expect(editor.kinds == [.paragraph])
        #expect(editor.texts == ["a#  # "])
    }

    @Test("Быстрые символы работают и в пунктах списков, и в чекбоксах; вложенность остаётся, у заголовков — 0", arguments: [
        (EditorFixture.Spec.bullet("", indent: 2), "1.", BlockKind.numberedItem, 2),
        (.bullet("", indent: 1), "[]", .checkbox, 1),
        (.numbered("", indent: 1), "[ ]", .checkbox, 1),
        (.checkbox("", indent: 1, checked: true), "-", .bulletItem, 1),
        (.checkbox(""), "*", .bulletItem, 0),
        (.numbered("", indent: 3), "#", .heading1, 0),
        (.bullet("", indent: 1), "###", .heading3, 0),
        (.heading(1, ""), "##", .heading2, 0),
    ])
    func shortcutInAnyBlock(spec: EditorFixture.Spec, prefix: String, kind: BlockKind, indent: Int) throws {
        let editor = try EditorFixture([.bullet("выше"), spec])
        editor.placeCaret(inBlock: 1)

        editor.type(prefix + " ")
        editor.type("дело")

        #expect(editor.kinds == [.bulletItem, kind])
        #expect(editor.texts == ["выше", "дело"], "Символы быстрого ввода в текст не попадают")
        #expect(editor.indents == [0, indent])
        let saved = try editor.savedBlocks()
        #expect(saved.map(\.isChecked) == [false, false], "Новый тип — не отмеченный чекбокс")
    }

    @Test("⌘Z после быстрого символа возвращает набранные символы и абзац")
    func undoRestoresPrefix() throws {
        let editor = try EditorFixture([.paragraph()])
        editor.placeCaret(inBlock: 0)
        editor.type("##")
        editor.type(" ")
        #expect(editor.kinds == [.heading2])

        editor.undo()

        #expect(editor.kinds == [.paragraph])
        #expect(editor.texts == ["##"])
        editor.redo()
        #expect(editor.kinds == [.heading2])
        #expect(editor.texts == [""])
    }

    @Test("⌫ в начале блока не-абзаца превращает его в абзац", arguments: [
        EditorFixture.Spec.heading(1, "Заголовок"), .bullet("пункт", indent: 1), .numbered("номер"), .checkbox("дело", checked: true),
    ])
    func backspaceAtStartMakesParagraph(spec: EditorFixture.Spec) throws {
        let editor = try EditorFixture([.paragraph("Выше"), spec])
        editor.placeCaret(inBlock: 1)

        editor.press(#selector(NSResponder.deleteBackward(_:)))

        #expect(editor.kinds == [.paragraph, .paragraph])
        #expect(editor.texts == ["Выше", spec.text], "Текст остаётся, блоки не склеиваются")
        #expect(editor.document.blocks[1].isChecked == false)
    }

    @Test("⌫ в начале абзаца склеивает его с предыдущим блоком")
    func backspaceAtStartOfParagraphMerges() throws {
        let editor = try EditorFixture([.bullet("пункт"), .paragraph("текст")])
        editor.placeCaret(inBlock: 1)

        editor.press(#selector(NSResponder.deleteBackward(_:)))

        #expect(editor.kinds == [.bulletItem])
        #expect(editor.texts == ["пункттекст"])
    }

    @Test("Enter в пустом пункте списка или чекбоксе превращает его в абзац", arguments: [
        EditorFixture.Spec.bullet("", indent: 2), .numbered(""), .checkbox(""),
    ])
    func enterInEmptyItemMakesParagraph(spec: EditorFixture.Spec) throws {
        let editor = try EditorFixture([.bullet("первый"), spec, .paragraph("ниже")])
        editor.placeCaret(inBlock: 1)

        editor.press(#selector(NSResponder.insertNewline(_:)))

        #expect(editor.kinds == [.bulletItem, .paragraph, .paragraph])
        #expect(editor.texts == ["первый", "", "ниже"], "Новый блок не появляется")
        #expect(editor.indents == [0, 0, 0])
    }

    @Test("Enter в пустом последнем пункте списка тоже выходит из списка")
    func enterInTrailingEmptyItem() throws {
        let editor = try EditorFixture([.paragraph()])
        editor.placeCaret(inBlock: 0)
        editor.type("- один")
        editor.press(#selector(NSResponder.insertNewline(_:)))
        #expect(editor.kinds == [.bulletItem, .bulletItem], "Enter в непустом пункте продолжает список")

        editor.press(#selector(NSResponder.insertNewline(_:)))

        #expect(editor.kinds == [.bulletItem, .paragraph])
        #expect(editor.texts == ["один", ""])
    }

    @Test("Разбор набранных символов")
    func prefixRecognition() {
        #expect(MarkdownShortcuts.kind(forTypedPrefix: "#") == .heading1)
        #expect(MarkdownShortcuts.kind(forTypedPrefix: "[ ]") == .checkbox)
        #expect(MarkdownShortcuts.kind(forTypedPrefix: "####") == nil)
        #expect(MarkdownShortcuts.kind(forTypedPrefix: "2.") == nil)
        #expect(MarkdownShortcuts.kind(forTypedPrefix: "") == nil)
        #expect(MarkdownShortcuts.kind(forTypedPrefix: "a-") == nil)
    }
}
