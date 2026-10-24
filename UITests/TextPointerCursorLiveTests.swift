import AppKit
import NotesCore
import XCTest

/// Системный указатель читается вне процесса приложения; NSCursor.current здесь был бы курсором runner.
final class TextPointerCursorLiveTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false; executionTimeAllowance = 180 }

    @MainActor
    func testCoveredH1ParagraphAndHandles() throws {
        let library = try UITestLibrary.make(for: self)
        try {
        let store = NotesStore(database: try AppDatabase.open(at: library.databaseURL), clock: HybridLogicalClock(deviceId: UUID()))
        let pageId = try store.write { tx in
            var page = try tx.createPage(title: "Указатель текста", icon: "🥰")
            page.cover = PageCover(source: .gallery("gradients_3"))
            try tx.updatePage(page)
            for block in try tx.blocks(ofPage: page.id) { try tx.deleteBlock(block.id) }
            var key: FractionalSortKey?
            for (kind, text) in [(BlockKind.heading1, "Заголовок первого уровня"), (.paragraph, "Текст абзаца для проверки указателя."), (.paragraph, "")] {
                key = .between(key, nil)
                try tx.insertBlock(Block(pageId: page.id, kind: kind, text: InlineText(text), sortKey: key!))
            }
            return page.id
        }
        try store.saveWindowState(WindowState(windowId: WindowState.mainWindowId, openPageId: pageId))
        }()
        let app = library.launchApp(appearance: "light")
        app.activate()
        addTeardownBlock { @MainActor in app.terminate() }
        XCTAssertTrue(app.pageTitle.waitForExistence(timeout: 10))
        app.pageTitle.click()
        let window = app.windows.firstMatch
        let title = app.pageTitle.frame
        let origin = window.coordinate(withNormalizedOffset: .zero)
        func hover(_ point: CGPoint) {
            origin.withOffset(CGVector(dx: point.x - window.frame.minX, dy: point.y - window.frame.minY)).hover()
        }
        hover(CGPoint(x: title.minX + 30, y: title.midY))
        let beam = try XCTUnwrap(NSCursor.currentSystem)
        hover(CGPoint(x: window.frame.midX, y: window.frame.minY + 12))
        let arrow = try XCTUnwrap(NSCursor.currentSystem)
        print("CURSOR-REFERENCE beam=\(beam.hotSpot)/\(beam.image.size) arrow=\(arrow.hotSpot)/\(arrow.image.size)")
        XCTAssertNotEqual(beam.hotSpot, arrow.hotSpot, "Калибровка не различила текстовое поле и заголовок окна")
        for (name, cursor) in [("ibeam", beam), ("arrow", arrow)] {
            let attachment = XCTAttachment(image: cursor.image)
            attachment.name = "cursor-reference-\(name)"; attachment.lifetime = .keepAlways; add(attachment)
        }
        let sampler = TextCursorSampler(beam: beam)
        let timer = Timer(timeInterval: 0.01, repeats: true) { _ in MainActor.assumeIsolated { sampler.sample() } }
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate() }
        func check(_ name: String, _ expected: NSCursor) throws {
            let cursor = try XCTUnwrap(NSCursor.currentSystem, "Системный курсор недоступен")
            print("SYSTEM-CURSOR \(name): hotspot=\(cursor.hotSpot) size=\(cursor.image.size) expected=\(expected.hotSpot)/\(expected.image.size)")
            XCTAssertEqual(cursor.hotSpot, expected.hotSpot, name)
            XCTAssertEqual(cursor.image.size, expected.image.size, name)
        }
        for (name, y) in [("h1", title.maxY + 42), ("paragraph", title.maxY + 90), ("empty", title.maxY + 130)] {
            sampler.region = CGRect(x: title.minX, y: y - 10, width: title.width, height: 20)
            for step in 0..<12 {
                hover(CGPoint(x: title.minX + 12 + CGFloat(step) * 8, y: y))
                try check("\(name)-move-\(step)", beam)
            }
            // Пока мышь стоит, ловим возврат стрелки после обновления tracking/cursor rects.
            for sample in 0..<20 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                try check("\(name)-still-\(sample)", beam)
            }
            print("CURSOR-SAMPLES \(name) total=\(sampler.samples) wrong=\(sampler.wrong)")
            XCTAssertGreaterThan(sampler.samples, 0, "Фоновый сбор курсора не работал")
            XCTAssertEqual(sampler.wrong, 0, "Указатель менялся во время движения/остановки")
            sampler.region = nil
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "text-cursor-\(name)"; shot.lifetime = .keepAlways; add(shot)
            if name != "empty" {
                XCTAssertTrue(app.blockDragHandle.waitForExistence(timeout: 3))
                let handle = app.blockDragHandle.frame
                hover(CGPoint(x: handle.midX, y: handle.midY))
                try check("\(name)-handle", arrow)
            }
        }
    }
}

@MainActor
private final class TextCursorSampler {
    let beam: NSCursor
    var region: CGRect?
    var samples = 0
    var wrong = 0
    init(beam: NSCursor) { self.beam = beam }
    func sample() {
        guard let region, let screen = NSScreen.screens.first else { return }
        let point = NSEvent.mouseLocation
        guard region.contains(CGPoint(x: point.x, y: screen.frame.maxY - point.y)) else { return }
        samples += 1
        guard let cursor = NSCursor.currentSystem,
              cursor.hotSpot == beam.hotSpot, cursor.image.size == beam.image.size else {
            wrong += 1
            print("CURSOR-TRANSIENT at=\(point) cursor=\(String(describing: NSCursor.currentSystem?.hotSpot))")
            return
        }
    }
}
