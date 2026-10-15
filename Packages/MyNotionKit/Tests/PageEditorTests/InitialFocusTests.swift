import AppKit
import Testing
@testable import PageEditor

/// Куда встаёт курсор, когда страница появилась в окне. Страницу, открытую из дерева, фокус не трогает:
/// в дереве дальше работают стрелки, Enter и ⌘⌫ (contracts/editor-interactions.md, «Боковое дерево»).
@MainActor
@Suite("Фокус при открытии страницы")
struct InitialFocusTests {
    @Test("Открытая из дерева страница фокус не забирает, но готова к вводу", arguments: [true, false])
    func unchangedFocusStaysInTree(keepFocus: Bool) async throws {
        let editor = try EditorFixture([.paragraph("Текст")])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled],
                              backing: .buffered, defer: true)
        let content = NSView(frame: window.contentLayoutRect)
        let tree = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        content.addSubview(tree)
        window.contentView = content
        window.makeFirstResponder(tree)
        let responderBefore = window.firstResponder

        let page = PageTextView(document: editor.document, initialFocus: keepFocus ? .unchanged : .body)
        let ready = AsyncStream<Void> { continuation in page.onReady = { continuation.yield() } }
        content.addSubview(page)
        var readyEvents = ready.makeAsyncIterator()
        _ = await readyEvents.next()

        if keepFocus {
            #expect(window.firstResponder === responderBefore, "фокус ушёл из дерева в \(String(describing: window.firstResponder))")
        } else {
            #expect(window.firstResponder === page, "щелчок по подстранице ставит курсор в текст")
        }
    }
}
