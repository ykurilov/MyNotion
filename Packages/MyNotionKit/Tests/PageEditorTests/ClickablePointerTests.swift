import AppKit
import Testing
@testable import PageEditor

/// Над тем, что срабатывает щелчком (квадрат чекбокса, строка блока-ссылки), курсор — «палец»; над текстом пункта — I-beam.
@MainActor
@Suite("Указатель над чекбоксом и блоком-ссылкой", .serialized)
struct ClickablePointerTests {
    private func cursor(at point: NSPoint, in editor: EditorFixture) throws -> NSCursor {
        let location = editor.textView.convert(point, to: nil)
        NSCursor.arrow.set()
        let moved = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: location, modifierFlags: [], timestamp: 0,
            windowNumber: editor.window.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0))
        editor.textView.mouseMoved(with: moved)
        return NSCursor.current
    }

    @Test("Над квадратиком чекбокса — палец, над текстом пункта — I-beam")
    func checkbox() throws {
        let editor = try EditorFixture([.checkbox("Дело")])
        let view = editor.textView
        view.layoutSubtreeIfNeeded()
        view.textLayoutManager?.ensureLayout(for: try #require(view.textLayoutManager).documentRange)
        let square = try #require(view.checkboxRect(ofBlock: view.document.blocks[0].id))
        #expect(try cursor(at: NSPoint(x: square.midX, y: square.midY), in: editor) == .pointingHand)
        let line = try #require(view.markerLine(ofBlockAt: 0))
        let text = NSPoint(x: view.textContainerOrigin.x + 60, y: view.textContainerOrigin.y + line.top + line.height / 2)
        #expect(try cursor(at: text, in: editor) == .iBeam)
    }

    @Test("Над названием и над пустой частью строки блока-ссылки — палец")
    func pageLinkRow() throws {
        let editor = try EditorFixture([.paragraph("Текст"), EditorFixture.Spec(kind: .pageLink, link: UUID())])
        let view = editor.textView
        view.layoutSubtreeIfNeeded()
        view.textLayoutManager?.ensureLayout(for: try #require(view.textLayoutManager).documentRange)
        let line = try #require(view.markerLine(ofBlockAt: 1))
        let y = view.textContainerOrigin.y + line.top + line.height / 2
        let column = line.markerColumn.offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
        for x in [column.minX + 40, column.minX + 300] {
            #expect(try cursor(at: NSPoint(x: x, y: y), in: editor) == .pointingHand, "x=\(x)")
        }
    }
}
