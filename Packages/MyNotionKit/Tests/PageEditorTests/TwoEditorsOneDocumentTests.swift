import AppKit
import Foundation
import Testing
@testable import NotesCore
@testable import PageEditor

/// Одна страница в двух окнах (FR-029): оба редактора правят один `PageDocument` (research R5).
/// Набор в одном сразу виден в другом; свой текст редактор не перерисовывает, его отмена цела.
@MainActor
@Suite("Два редактора одной страницы")
struct TwoEditorsOneDocumentTests {
    @Test("Набор в первом редакторе виден во втором, и обратно")
    func typingIsMirroredBothWays() throws {
        let fixture = try EditorFixture([.paragraph("раз"), .paragraph("второй")])
        let other = SecondEditor(document: fixture.document)

        fixture.placeCaret(inBlock: 0, at: nil)
        fixture.type(" два")
        #expect(other.textView.string == "раз два\nвторой\n")

        other.placeCaret(at: (other.textView.string as NSString).length - 1)
        other.type("!")
        #expect(fixture.textView.string == "раз два\nвторой!\n")
        #expect(fixture.texts == ["раз два", "второй!"])
    }

    @Test("Новый блок из одного редактора появляется во втором, курсор второго остаётся в своём блоке")
    func newBlockIsMirroredAndCaretStays() throws {
        let fixture = try EditorFixture([.paragraph("первый"), .paragraph("второй")])
        let other = SecondEditor(document: fixture.document)
        other.placeCaret(at: (other.textView.string as NSString).length - 3)

        fixture.placeCaret(inBlock: 0, at: nil)
        fixture.type("\n")
        fixture.type("вставка")

        #expect(other.textView.string == "первый\nвставка\nвторой\n")
        let caret = other.textView.selectedRange()
        #expect(caret == NSRange(location: (other.textView.string as NSString).length - 3, length: 0))
    }

    @Test("Свой набор не перерисовывается: отмена в редакторе, где печатали, работает")
    func ownTypingKeepsUndo() throws {
        let fixture = try EditorFixture([.paragraph("раз")])
        _ = SecondEditor(document: fixture.document)

        fixture.placeCaret(inBlock: 0, at: nil)
        fixture.type("!")
        #expect(fixture.undoManager.canUndo)
        fixture.undoManager.undo()
        #expect(fixture.texts == ["раз"])
    }

    @Test("Новое название из одного редактора — в шапке второго")
    func titleIsMirrored() throws {
        let fixture = try EditorFixture([.paragraph("текст")])
        let other = SecondEditor(document: fixture.document)

        // Как набор в поле названия: поле зовёт `onTitleChange` на каждую правку.
        fixture.textView.header.titleField.stringValue = "Новое имя"
        fixture.textView.header.onTitleChange?("Новое имя")

        #expect(fixture.document.page.title == "Новое имя")
        #expect(other.textView.header.titleField.stringValue == "Новое имя")
    }
}

/// Второе окно той же страницы: свой редактор над тем же документом.
@MainActor
private final class SecondEditor {
    let textView: PageTextView
    let window: NSWindow
    let undoManager = UndoManager()

    init(document: PageDocument) {
        textView = PageTextView(document: document, initialFocus: .body)
        undoManager.groupsByEvent = false
        textView.fallbackUndoManager = undoManager
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled], backing: .buffered, defer: true)
        let scroll = NSScrollView(frame: window.contentLayoutRect)
        scroll.documentView = textView
        textView.frame.size.width = 1200
        window.contentView = scroll
        window.makeFirstResponder(textView)
    }

    func placeCaret(at location: Int) {
        textView.setSelectedRange(NSRange(location: location, length: 0))
    }

    func type(_ text: String) {
        for character in text {
            undoManager.beginUndoGrouping()
            textView.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
            undoManager.endUndoGrouping()
        }
    }
}
