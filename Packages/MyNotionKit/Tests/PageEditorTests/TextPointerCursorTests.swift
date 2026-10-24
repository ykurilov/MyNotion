import AppKit
import Testing
@testable import PageEditor

@MainActor
@Suite("Указатель над текстом страницы", .serialized)
struct TextPointerCursorTests {
    @Test("H1, абзац и пустая колонка сохраняют I-beam при mouseMoved и cursorUpdate", arguments: [false, true])
    func textRemainsIBeam(enteringFromArrow: Bool) throws {
        let fixture = try EditorFixture([.heading(1, "Заголовок"), .paragraph("Абзац"), .paragraph()], icon: "🥰")
        let view = fixture.textView
        view.setCover(NSView(), height: 200)
        view.layoutSubtreeIfNeeded()
        let manager = try #require(view.textLayoutManager)
        manager.ensureLayout(for: manager.documentRange)
        for index in 0..<3 {
            let line = try #require(view.markerLine(ofBlockAt: index))
            for step in 0..<5 {
                let point = NSPoint(x: view.textContainerOrigin.x + 20 + CGFloat(step) * 20,
                                    y: view.textContainerOrigin.y + line.top + line.height / 2)
                let location = view.convert(point, to: nil)
                (enteringFromArrow ? NSCursor.arrow : NSCursor.iBeam).set()
                let moved = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: location,
                    modifierFlags: [], timestamp: 0, windowNumber: fixture.window.windowNumber,
                    context: nil, eventNumber: step, clickCount: 0, pressure: 0))
                view.mouseMoved(with: moved)
                #expect(NSCursor.current == NSCursor.iBeam, "block\(index) step\(step): mouseMoved changed I-beam")
                if enteringFromArrow { NSCursor.arrow.set() }
                let update = try #require(NSEvent.enterExitEvent(with: .cursorUpdate, location: location,
                    modifierFlags: [], timestamp: 0, windowNumber: fixture.window.windowNumber,
                    context: nil, eventNumber: step, trackingNumber: 0, userData: nil))
                view.cursorUpdate(with: update)
                #expect(NSCursor.current == NSCursor.iBeam, "block\(index) step\(step): cursorUpdate changed I-beam to \(NSCursor.current)")
            }
        }
    }
}
