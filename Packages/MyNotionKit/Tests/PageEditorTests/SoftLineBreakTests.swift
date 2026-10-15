import AppKit
import Testing
@testable import NotesCore
@testable import PageEditor
import VisualStyle

/// Перенос строки внутри блока (FR-032): Shift+Enter переносит строку, блок остаётся одним. В тексте блока перенос —
/// `\n`, на странице — разрыв строки U+2028: TextKit не считает его границей абзаца (data-model.md, «Перенос строки»).
@MainActor
@Suite("Перенос строки внутри блока")
struct SoftLineBreakTests {
    static let lineSeparator = "\u{2028}"

    private func pressReturn(_ editor: EditorFixture, modifiers: NSEvent.ModifierFlags = []) throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                                  windowNumber: editor.window.windowNumber, context: nil, characters: "\r",
                                                  charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        editor.step { editor.textView.keyDown(with: event) }
    }

    @Test("Shift+Enter переносит строку в том же блоке, Enter создаёт новый блок", arguments: [BlockKind.paragraph, .bulletItem, .numberedItem, .checkbox, .heading2])
    func shiftReturnBreaksLine(_ kind: BlockKind) throws {
        let editor = try EditorFixture([EditorFixture.Spec(kind: kind, text: "Первая"), .paragraph("Ниже")])
        editor.placeCaret(inBlock: 0, at: nil)
        try pressReturn(editor, modifiers: .shift)
        editor.type("Вторая")
        #expect(editor.document.blocks.count == 2, "\(kind): блоков \(editor.document.blocks.count)")
        #expect(editor.kinds == [kind, .paragraph])
        #expect(editor.texts == ["Первая\nВторая", "Ниже"])
        #expect(editor.textView.string.hasPrefix("Первая" + Self.lineSeparator + "Вторая\n"), "На странице не разрыв строки: \(editor.textView.string.debugDescription)")
        try pressReturn(editor)
        #expect(editor.document.blocks.count == 3, "Enter не создал новый блок")
    }

    @Test("Перенос сохраняется и читается обратно: в базе `\\n`, после открытия — тот же один блок")
    func breakSurvivesReload() throws {
        let editor = try EditorFixture([.bullet("Пункт")])
        editor.placeCaret(inBlock: 0, at: nil)
        try pressReturn(editor, modifiers: .shift)
        editor.type("продолжение")
        let saved = try editor.savedBlocks()
        #expect(saved.map(\.text.string) == ["Пункт\nпродолжение"])
        let reopened = try EditorFixture([.bullet("Пункт\nпродолжение")])
        #expect(reopened.document.blocks.count == 1)
        #expect(reopened.textView.string == "Пункт" + Self.lineSeparator + "продолжение\n")
        #expect(reopened.texts == ["Пункт\nпродолжение"], "Правка не тронула текст, а он изменился")
        reopened.placeCaret(inBlock: 0, at: nil)
        reopened.type("!")
        #expect(reopened.texts == ["Пункт\nпродолжение!"])
    }

    @Test("Маркер у первой строки, следующие строки — с тем же отступом текста; обе строки — один блок")
    func linesShareBlock() throws {
        let editor = try EditorFixture([.bullet("Первая\nВторая\nТретья", indent: 1), .paragraph("Ниже")])
        let textView = editor.textView
        let layoutManager = try #require(textView.textLayoutManager)
        let storage = try #require(textView.textContentStorage)
        let location = try #require(storage.location(storage.documentRange.location, offsetBy: 0))
        let fragment = try #require(layoutManager.textLayoutFragment(for: location))
        let lines = fragment.textLineFragments.filter { $0.characterRange.length > 0 }
        try #require(lines.count == 3, "Строк в блоке \(lines.count)")
        let line = try #require(textView.markerLine(ofBlockAt: 0))
        for (index, text) in lines.enumerated() {
            let x = fragment.layoutFragmentFrame.minX + text.typographicBounds.minX + text.locationForCharacter(at: text.characterRange.location).x
            #expect(abs(x - line.caretX) <= 0.5, "Строка \(index) с \(x), текст блока с \(line.caretX)")
            let y = textView.textContainerOrigin.y + fragment.layoutFragmentFrame.minY + text.typographicBounds.midY
            #expect(textView.blockIndex(atY: y) == 0, "Строка \(index) — не блок 0")
        }
        let firstLineTop = fragment.layoutFragmentFrame.minY + lines[0].typographicBounds.minY
        #expect(line.top <= firstLineTop + 0.5 && line.top + line.height <= firstLineTop + lines[0].typographicBounds.height + 0.5,
                "Маркер не у первой строки: \(line), первая строка с \(firstLineTop)")
    }

    @Test("Быстрые символы — только в начале блока, не в начале второй строки")
    func shortcutsOnlyAtBlockStart() throws {
        let editor = try EditorFixture([.paragraph("Строка")])
        editor.placeCaret(inBlock: 0, at: nil)
        try pressReturn(editor, modifiers: .shift)
        editor.type("- ")
        #expect(editor.kinds == [.paragraph])
        #expect(editor.texts == ["Строка\n- "])
        editor.placeCaret(inBlock: 0, at: 0)
        editor.type("# ")
        #expect(editor.kinds == [.heading1])
        #expect(editor.texts == ["Строка\n- "])
    }

    @Test("Тип меняется у блока целиком, перестановка и удаление — тоже целиком")
    func blockActsWhole() throws {
        let editor = try EditorFixture([.paragraph("Первая\nВторая"), .paragraph("Ниже")])
        editor.placeCaret(inBlock: 0, at: 9)
        editor.perform(.setKind(.bulletItem))
        #expect(editor.kinds == [.bulletItem, .paragraph])
        #expect(editor.texts == ["Первая\nВторая", "Ниже"])
        editor.perform(.moveBlocksDown)
        #expect(editor.texts == ["Ниже", "Первая\nВторая"])
        #expect(editor.textView.string == "Ниже\nПервая" + Self.lineSeparator + "Вторая\n")
        editor.step { editor.textView.removeBlocks(at: 1..<2) }
        #expect(editor.texts == ["Ниже"])
    }

    @Test("Выделение текста — полосы по строкам и внутри блока с переносом, и дальше него; выделенный блок — подложка на обе строки")
    func selectionInsideBrokenBlock() throws {
        let editor = try EditorFixture([.paragraph("Первая\nВторая"), .paragraph("Ниже")])
        let textView = editor.textView
        textView.setSelectedRange(NSRange(location: 0, length: 13))
        #expect(!textView.isBlockSelection, "Выделение внутри блока с переносом показано блоком")
        let bands = textView.selectionHighlightRects()
        #expect(bands.count == 2, "Полос \(bands.count): \(bands)")
        textView.setSelectedRange(NSRange(location: 3, length: 14))
        #expect(!textView.isBlockSelection, "Выделение текста через блоки показано блоками")
        #expect(textView.selectionHighlightRects().count == 3, "Полос \(textView.selectionHighlightRects())")
        textView.selectBlocks(0..<1)
        let rects = textView.selectionHighlightRects()
        try #require(rects.count == 1)
        #expect(rects[0].height >= 48 + 6 - 0.5, "Подложка блока с переносом не на обе строки: \(rects[0])")
    }

    @Test("Курсор в начале второй строки — у начала текста блока")
    func caretAtSecondLine() throws {
        let editor = try EditorFixture([.numbered("Первая\nВторая")])
        editor.textView.caret.showsWithoutKeyWindow = true
        editor.placeCaret(inBlock: 0, at: 7)
        let line = try #require(editor.textView.markerLine(ofBlockAt: 0))
        let rect = editor.textView.caret.frame
        let textStart = line.caretX + editor.textView.textContainerOrigin.x
        #expect(rect.minX >= textStart - 1 && rect.minX <= textStart, "Курсор с \(rect.minX), текст с \(textStart)")
        #expect(rect.minY > editor.textView.textContainerOrigin.y + line.top + line.height - 1, "Курсор не на второй строке: \(rect)")
    }

    @Test("Копирование в другие программы: перенос строки — обычный перевод строки")
    func copyWritesPlainNewline() throws {
        let editor = try EditorFixture([.paragraph("Раз\nДва")])
        editor.textView.setSelectedRange(NSRange(location: 0, length: 7))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("MyNotionTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        #expect(editor.textView.writeSelection(to: pasteboard, types: [.string]))
        #expect(pasteboard.string(forType: .string) == "Раз\nДва")
    }

    @Test("Вставка многострочного текста из других программ: каждая строка — свой блок, и разрыв строки тоже")
    func multilinePasteSplitsBlocks() throws {
        let editor = try EditorFixture([.paragraph("")])
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("MyNotionTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("Раз\nДва" + Self.lineSeparator + "Три", forType: .string)
        editor.step { editor.textView.paste(from: pasteboard) }
        #expect(editor.texts == ["Раз", "Два", "Три"])
    }
}
