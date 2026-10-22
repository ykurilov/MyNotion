import AppKit
import Testing
@testable import PageEditor

@MainActor
@Suite("Наведение не меняет раскладку текста")
struct HoverLayoutTests {
    @Test("Медленное движение над заголовком и абзацами оставляет строки на месте")
    func hoverKeepsLineGeometry() throws {
        let editor = try EditorFixture([
            .heading(1, "Блок с текстом: заголовок 1"),
            .paragraph("Текст под заголовком для проверки наведения."),
            .bullet("Первый пункт"), .bullet("Второй пункт"), .paragraph(""),
        ], icon: "🥰")
        let view = editor.textView
        view.setCover(NSView(), height: 200)
        view.layoutSubtreeIfNeeded()
        let manager = try #require(view.textLayoutManager)
        manager.ensureLayout(for: manager.documentRange)
        view.layoutSubtreeIfNeeded()
        func frames() -> [CGRect] {
            var result: [CGRect] = []
            manager.enumerateTextLayoutFragments(from: manager.documentRange.location) { fragment in
                result.append(fragment.layoutFragmentFrame)
                return true
            }
            return result
        }
        editor.window.makeFirstResponder(view.header.titleField)
        let area = CGRect(x: view.textContainerOrigin.x + 2, y: view.textContainerOrigin.y,
                          width: view.textContainer!.size.width - 2, height: 180)
        func pixels() throws -> Data {
            let bitmap = try ViewPixels(view, appearance: .aqua, rect: area).bitmap
            return Data(bytes: try #require(bitmap.bitmapData), count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        }
        let initialPixels = try pixels()
        let initial = frames()
        #expect(initial.count >= editor.document.blocks.count)
        for index in 0..<4 {
            let line = try #require(view.markerLine(ofBlockAt: index))
            let point = NSPoint(x: view.textContainerOrigin.x + 50, y: view.textContainerOrigin.y + line.top + line.height / 2)
            for step in 0..<20 {
                let local = NSPoint(x: point.x + CGFloat(step) * 9, y: point.y)
                let event = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: view.convert(local, to: nil),
                    modifierFlags: [], timestamp: 0, windowNumber: editor.window.windowNumber,
                    context: nil, eventNumber: step, clickCount: 0, pressure: 0))
                view.mouseMoved(with: event)
                #expect(frames() == initial, "Блок \(index), движение \(step): строки сдвинулись")
                #expect(view.blockHandles.blockId == editor.document.blocks[index].id)
                #expect(try pixels() == initialPixels, "Блок \(index), движение \(step): рисунок текста изменился")
            }
        }
    }
}
