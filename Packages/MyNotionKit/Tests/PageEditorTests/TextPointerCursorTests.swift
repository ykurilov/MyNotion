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

    @Test("mouseMoved над ручкой не оставляет I-beam от текста")
    func handleRestoresArrow() throws {
        let fixture = try EditorFixture([.heading(1, "Заголовок")])
        let view = fixture.textView
        view.layoutSubtreeIfNeeded()
        let manager = try #require(view.textLayoutManager)
        manager.ensureLayout(for: manager.documentRange)
        let line = try #require(view.markerLine(ofBlockAt: 0))
        view.updateBlockHandles(atWindowPoint: view.convert(
            NSPoint(x: view.textContainerOrigin.x + 20,
                    y: view.textContainerOrigin.y + line.top + line.height / 2), to: nil))
        let handle = view.blockHandles.dragHandle
        #expect(!view.blockHandles.isHidden)
        let location = handle.convert(NSPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
        NSCursor.iBeam.set()
        let moved = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: location,
            modifierFlags: [], timestamp: 0, windowNumber: fixture.window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 0, pressure: 0))
        view.mouseMoved(with: moved)
        #expect(NSCursor.current == NSCursor.arrow, "Ручка унаследовала I-beam от текста после mouseMoved")
    }


    @Test("Иконка и кнопка шапки не наследуют I-beam", arguments: [true, false])
    func headerChromeRestoresArrow(icon: Bool) throws {
        let fixture = try EditorFixture([.paragraph("Текст")], icon: "🥰")
        let header = fixture.textView.header
        let control: NSView
        if icon {
            control = try #require(header.subviews.compactMap { $0 as? PageIconView }.first)
        } else {
            let button = PageHeaderButton(symbolName: "photo", title: "Обложка", identifier: "test-cover")
            header.addSubview(button)
            button.frame = NSRect(x: 0, y: 0, width: 100, height: 28)
            control = button
        }
        let update = try #require(NSEvent.enterExitEvent(with: .cursorUpdate, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: fixture.window.windowNumber,
            context: nil, eventNumber: 1, trackingNumber: 0, userData: nil))
        NSCursor.iBeam.set()
        control.cursorUpdate(with: update)
        #expect(NSCursor.current == NSCursor.arrow, "Шапка унаследовала I-beam")
    }


    @Test("Текстовый родитель не заменяет курсор разделителя колонок")
    func embeddedCursorIsPreserved() throws {
        let fixture = try EditorFixture([.paragraph("Текст")])
        let view = fixture.textView
        view.layoutSubtreeIfNeeded()
        let divider = ColumnDividerView(frame: NSRect(x: view.textContainerOrigin.x + 100,
                                                     y: view.textContainerOrigin.y + 5, width: 12, height: 40))
        view.addSubview(divider)
        let location = divider.convert(NSPoint(x: 6, y: 20), to: nil)
        let event = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: location,
            modifierFlags: [], timestamp: 0, windowNumber: fixture.window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 0, pressure: 0))
        NSCursor.resizeLeftRight.set()
        view.mouseMoved(with: event)
        #expect(NSCursor.current == NSCursor.resizeLeftRight)
        let update = try #require(NSEvent.enterExitEvent(with: .cursorUpdate, location: location,
            modifierFlags: [], timestamp: 0, windowNumber: fixture.window.windowNumber,
            context: nil, eventNumber: 2, trackingNumber: 0, userData: nil))
        view.cursorUpdate(with: update)
        #expect(NSCursor.current == NSCursor.resizeLeftRight, "cursorUpdate родителя подменил курсор вложенного вида")
    }

}
