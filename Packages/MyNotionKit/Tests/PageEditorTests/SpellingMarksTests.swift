import AppKit
import Testing
@testable import PageEditor

/// Окно, которое тест назначает ключевым, не показывая его на экране.
private final class KeyStubWindow: NSWindow {
    var isKeyStub = false
    override var isKeyWindow: Bool { isKeyStub }

    func setKey(_ key: Bool) {
        isKeyStub = key
        NotificationCenter.default.post(name: key ? NSWindow.didBecomeKeyNotification : NSWindow.didResignKeyNotification, object: self)
    }
}

@MainActor
@Suite("Отметки орфографии")
struct SpellingMarksTests {
    private func editorInStubWindow() throws -> (EditorFixture, KeyStubWindow) {
        let editor = try EditorFixture([.paragraph("Ашибка в тексте")])
        let window = KeyStubWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled], backing: .buffered, defer: true)
        let scroll = try #require(editor.window.contentView)
        editor.window.contentView = NSView()
        window.contentView = scroll
        window.makeFirstResponder(editor.textView)
        return (editor, window)
    }

    @Test("Красные подчёркивания видны только в тексте с курсором в ключевом окне (№ 20)")
    func marksOnlyInActiveText() throws {
        let (editor, window) = try editorInStubWindow()
        let textView = editor.textView

        window.setKey(true)
        #expect(textView.isContinuousSpellCheckingEnabled, "Ключевое окно, курсор в тексте — проверка идёт")

        window.setKey(false)
        #expect(!textView.isContinuousSpellCheckingEnabled, "Окно не ключевое — отметок нет")

        window.setKey(true)
        #expect(textView.isContinuousSpellCheckingEnabled)
        textView.header.focusTitle()
        #expect(!textView.isContinuousSpellCheckingEnabled, "Курсор в названии — отметок в тексте нет")
        window.makeFirstResponder(textView)
        #expect(textView.isContinuousSpellCheckingEnabled, "Курсор вернулся — проверка снова идёт")
    }

    @Test("Выключенная в меню «Проверять правописание при наборе» не включается сама (№ 20)")
    func menuChoiceIsKept() throws {
        let (editor, window) = try editorInStubWindow()
        let textView = editor.textView
        window.setKey(true)
        textView.toggleContinuousSpellChecking(nil)
        #expect(!textView.isContinuousSpellCheckingEnabled)
        window.setKey(false)
        window.setKey(true)
        #expect(!textView.isContinuousSpellCheckingEnabled, "Выбор в меню сохраняется")
        textView.toggleContinuousSpellChecking(nil)
        #expect(textView.isContinuousSpellCheckingEnabled)
    }
}
