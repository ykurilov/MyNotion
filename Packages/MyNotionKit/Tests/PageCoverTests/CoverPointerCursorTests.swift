import AppKit
import Testing
import NotesCore
@testable import PageCover

@MainActor
@Suite("Указатель обложки", .serialized)
struct CoverPointerCursorTests {
    @Test("Обложка выбирает I-beam, режим перемещения сохраняет open hand")
    func cursorOwnership() throws {
        let view = CoverView(cover: PageCover(source: .gallery("gradients_3")), fileURL: { _ in nil })
        let host = NSTextView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        host.addSubview(view)
        view.frame = NSRect(x: 0, y: 0, width: 1200, height: 200)
        defer { withExtendedLifetime(host) {} }
        let event = try #require(NSEvent.enterExitEvent(with: .cursorUpdate, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 1, trackingNumber: 0, userData: nil))
        NSCursor.iBeam.set()
        view.cursorUpdate(with: event)
        #expect(NSCursor.current == NSCursor.iBeam)
        view.beginReposition()
        view.cursorUpdate(with: event)
        #expect(NSCursor.current == NSCursor.openHand)
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 500, y: 100),
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 2, clickCount: 1, pressure: 1))
        view.mouseDown(with: down)
        #expect(NSCursor.current == NSCursor.closedHand)
        view.mouseUp(with: down)
        #expect(NSCursor.current == NSCursor.openHand)
        view.saveButton.cursorUpdate(with: event)
        #expect(NSCursor.current == NSCursor.pointingHand, "Кнопка обложки не должна наследовать open hand или I-beam")
    }
}
