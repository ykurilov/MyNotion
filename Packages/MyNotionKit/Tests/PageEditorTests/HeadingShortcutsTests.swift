import AppKit
import Testing
@testable import NotesCore
@testable import PageEditor

/// ⌥⌘1, ⌥⌘2, ⌥⌘3 — блок под курсором или выделенные блоки становятся заголовком, ⌥⌘0 — обычным текстом, как в Notion.
/// Тем же путём, что «Преобразовать в»: текст и курсор на месте, ⌘Z возвращает.
@MainActor
@Suite("Заголовки клавишами")
struct HeadingShortcutsTests {
    @Test("⌥⌘0…3 — тип блока; в русской раскладке те же цифры; без ⌥ — не наше")
    func keyBindings() {
        #expect(EditorKeyBindings.command(characters: "1", modifiers: [.command, .option]) == .setKind(.heading1))
        #expect(EditorKeyBindings.command(characters: "2", modifiers: [.command, .option]) == .setKind(.heading2))
        #expect(EditorKeyBindings.command(characters: "3", modifiers: [.command, .option]) == .setKind(.heading3))
        #expect(EditorKeyBindings.command(characters: "0", modifiers: [.command, .option]) == .setKind(.paragraph))
        #expect(EditorKeyBindings.command(characters: "1", modifiers: [.command]) == nil, "⌘1 — не заголовок")
        #expect(EditorKeyBindings.command(characters: "4", modifiers: [.command, .option]) == nil)
    }

    @Test("⌥⌘2 делает заголовок; курсор остаётся; ⌥⌘0 возвращает текст; ⌘Z отменяет")
    func caretBlockBecomesHeading() throws {
        let editor = try EditorFixture([.paragraph("раз"), .paragraph("два")])
        editor.placeCaret(inBlock: 1, at: 2)
        editor.step { editor.textView.turnIntoHeading2(nil) }
        #expect(editor.kinds == [.paragraph, .heading2])
        #expect(editor.texts == ["раз", "два"])
        #expect(editor.textView.selectedRange() == NSRange(location: editor.textLocation(ofBlock: 1) + 2, length: 0))
        editor.step { editor.textView.turnIntoText(nil) }
        #expect(editor.kinds == [.paragraph, .paragraph])
        editor.undo()
        #expect(editor.kinds == [.paragraph, .heading2])
    }

    @Test("Выделенные блоки — все сразу; выделение остаётся")
    func selectedBlocksBecomeHeadings() throws {
        let editor = try EditorFixture([.paragraph("раз"), .paragraph("два"), .paragraph("три")])
        let start = editor.textLocation(ofBlock: 0) + 1
        let selection = NSRange(location: start, length: editor.textLocation(ofBlock: 1) + 2 - start)
        editor.textView.setSelectedRange(selection)
        editor.step { editor.textView.turnIntoHeading1(nil) }
        #expect(editor.kinds == [.heading1, .heading1, .paragraph])
        #expect(editor.textView.selectedRange() == selection)
    }

    @Test("Заголовок того же уровня не меняется и не оставляет шага отмены")
    func sameHeadingIsUntouched() throws {
        let editor = try EditorFixture([.heading(3, "Под")])
        editor.placeCaret(inBlock: 0, at: nil)
        editor.textView.turnIntoHeading3(nil) // Без группы отмены: шаг здесь — уже ошибка.
        #expect(editor.kinds == [.heading3])
        #expect(editor.undoManager.canUndo == false)
    }

    @Test("Подсказки клавиш в «Преобразовать в»: Текст ⌥⌘0, Заголовки ⌥⌘1…3")
    func turnIntoHints() {
        let hints = Dictionary(uniqueKeysWithValues: PopupMenuItem.blockKinds.compactMap { item -> (BlockKind, String)? in
            guard case .setKind(let kind) = item.action, let hint = item.hint else { return nil }
            return (kind, hint)
        })
        #expect(hints == [.paragraph: "⌥⌘0", .heading1: "⌥⌘1", .heading2: "⌥⌘2", .heading3: "⌥⌘3"])
    }
}
