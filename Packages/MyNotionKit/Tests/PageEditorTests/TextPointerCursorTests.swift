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
    func handleRestoresPointingHand() throws {
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
        #expect(NSCursor.current == NSCursor.pointingHand, "Ручка унаследовала I-beam от текста после mouseMoved")
        let update = try #require(NSEvent.enterExitEvent(with: .cursorUpdate, location: location,
            modifierFlags: [], timestamp: 0, windowNumber: fixture.window.windowNumber,
            context: nil, eventNumber: 2, trackingNumber: 0, userData: nil))
        view.cursorUpdate(with: update)
        #expect(NSCursor.current == NSCursor.pointingHand, "cursorUpdate родителя затёр pointing hand ручки")
    }


    @Test("mouseMoved над ⋮⋮, + и иконкой ни разу не ставит I-beam: указатель не мигает", arguments: [0, 1, 2])
    func clickableNeverFlashesIBeam(target: Int) throws {
        let fixture = try EditorFixture([.heading(1, "Заголовок")], icon: "🥰")
        let view = fixture.textView
        view.layoutSubtreeIfNeeded()
        let manager = try #require(view.textLayoutManager)
        manager.ensureLayout(for: manager.documentRange)
        let line = try #require(view.markerLine(ofBlockAt: 0))
        view.updateBlockHandles(atWindowPoint: view.convert(
            NSPoint(x: view.textContainerOrigin.x + 20,
                    y: view.textContainerOrigin.y + line.top + line.height / 2), to: nil))
        let control: NSView = switch target {
        case 0: view.blockHandles.dragHandle
        case 1: view.blockHandles.addHandle
        default: try #require(view.header.subviews.compactMap { $0 as? PageIconView }.first)
        }
        let location = control.convert(NSPoint(x: control.bounds.midX, y: control.bounds.midY), to: nil)
        let moved = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: location,
            modifierFlags: [], timestamp: 0, windowNumber: fixture.window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 0, pressure: 0))
        // Живая трасса: NSTextView.mouseMoved ставил I-beam, следом наш код — руку; на экране это мигание.
        let set = CursorSetRecorder.record { view.mouseMoved(with: moved) }
        #expect(set == [NSCursor.pointingHand], "За одно событие поставлено \(set.count) указателей, нужен один: рука")
    }

    @Test("Над подстраницей, упоминанием и ссылкой — рука без I-beam, рядом в тексте — I-beam",
          arguments: ["page-icon", "page-title", "mention", "link", "text"])
    func clickableTextShowsPointingHand(target: String) throws {
        let subpage = UUID(), mentioned = UUID()
        var link = EditorFixture.Spec.paragraph()
        link.kind = .pageLink
        link.link = subpage
        let fixture = try EditorFixture([.paragraph("Текст и ссылка тут"), link, .paragraph("Упомянуть ")])
        let view = fixture.textView
        view.linkedPages = [subpage: LinkedPage(title: "Оффер", icon: nil)]
        view.mentionDirectory = MentionDirectory(pages: [mentioned: LinkedPage(title: "Планы", icon: "📘")])
        fixture.select(inBlock: 0, "ссылка")
        fixture.step { view.setLink(URL(string: "https://www.notion.so")!) }
        let atom = fixture.textLocation(ofBlock: 2) + 10
        fixture.step { view.insertAtom(.mention(mentioned), in: NSRange(location: atom, length: 0), blockAt: 2) }
        view.layoutSubtreeIfNeeded()
        let manager = try #require(view.textLayoutManager)
        manager.ensureLayout(for: manager.documentRange)
        func middle(ofCharacters range: NSRange) -> NSPoint {
            let screen = view.firstRect(forCharacterRange: range, actualRange: nil)
            let local = view.convert(fixture.window.convertFromScreen(screen), from: nil)
            return NSPoint(x: local.midX, y: local.midY)
        }
        let origin = view.textContainerOrigin
        let row = try #require(view.markerLine(ofBlockAt: 1))
        let rowY = origin.y + row.top + row.height / 2
        let point: NSPoint
        switch target {
        case "page-icon": point = NSPoint(x: origin.x + row.markerColumn.midX, y: rowY)
        case "page-title": point = NSPoint(x: origin.x + row.textStart + 15, y: rowY)
        case "mention": point = middle(ofCharacters: NSRange(location: atom, length: 1))
        case "link": point = middle(ofCharacters: NSRange(location: 8, length: 6))
        default: point = middle(ofCharacters: NSRange(location: 0, length: 5))
        }
        let expected: NSCursor = target == "text" ? .iBeam : .pointingHand
        let location = view.convert(point, to: nil)
        let moved = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: location,
            modifierFlags: [], timestamp: 0, windowNumber: fixture.window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 0, pressure: 0))
        NSCursor.arrow.set()
        let set = CursorSetRecorder.record { view.mouseMoved(with: moved) }
        #expect(set.last == expected, "\(target): после mouseMoved указатель \(String(describing: set.last))")
        if target != "text" { #expect(set == [NSCursor.pointingHand], "\(target): за одно событие \(set.count) указателей — мигание") }
        NSCursor.arrow.set()
        let update = try #require(NSEvent.enterExitEvent(with: .cursorUpdate, location: location,
            modifierFlags: [], timestamp: 0, windowNumber: fixture.window.windowNumber,
            context: nil, eventNumber: 2, trackingNumber: 0, userData: nil))
        view.cursorUpdate(with: update)
        #expect(NSCursor.current == expected, "\(target): cursorUpdate поставил \(NSCursor.current)")
    }

    @Test("Иконка и кнопка шапки выбирают pointing hand", arguments: [true, false])
    func headerChromeRestoresPointingHand(icon: Bool) throws {
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
        #expect(NSCursor.current == NSCursor.pointingHand, "Шапка унаследовала I-beam")
    }


    @Test("Родитель сохраняет курсор обложки, её кнопки и перемещения", arguments: [0, 1, 2])
    func coverCursorIsPreserved(mode: Int) throws {
        let fixture = try EditorFixture([.paragraph("Текст")], icon: "🥰")
        let view = fixture.textView
        let cover = NSView()
        view.setCover(cover, height: 200)
        view.layoutSubtreeIfNeeded()
        let location = cover.convert(NSPoint(x: cover.bounds.midX, y: 70), to: nil)
        let moved = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: location,
            modifierFlags: [], timestamp: 0, windowNumber: fixture.window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 0, pressure: 0))
        let cursor: NSCursor = mode == 0 ? .iBeam : mode == 1 ? .pointingHand : .openHand
        cursor.set()
        view.mouseMoved(with: moved)
        #expect(NSCursor.current == cursor, "mouseMoved родителя затёр курсор обложки")
        let update = try #require(NSEvent.enterExitEvent(with: .cursorUpdate, location: location,
            modifierFlags: [], timestamp: 0, windowNumber: fixture.window.windowNumber,
            context: nil, eventNumber: 2, trackingNumber: 0, userData: nil))
        view.cursorUpdate(with: update)
        #expect(NSCursor.current == cursor, "cursorUpdate родителя затёр курсор обложки")
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

/// Все NSCursor.set() за время блока: подменяет set() на запись и возвращает подлинный обратно.
@MainActor
enum CursorSetRecorder {
    nonisolated(unsafe) static var cursors: [NSCursor] = []

    static func record(_ body: () -> Void) -> [NSCursor] {
        let original = class_getInstanceMethod(NSCursor.self, #selector(NSCursor.set))!
        let recording = class_getInstanceMethod(NSCursor.self, #selector(NSCursor.recordedSet))!
        cursors = []
        method_exchangeImplementations(original, recording)
        body()
        method_exchangeImplementations(original, recording)
        return cursors
    }
}

extension NSCursor {
    @objc fileprivate func recordedSet() {
        CursorSetRecorder.cursors.append(self)
        recordedSet()
    }
}
