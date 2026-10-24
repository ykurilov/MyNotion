import AppKit
import NotesCore
import XCTest

/// Системный указатель читается вне процесса приложения; NSCursor.current здесь был бы курсором runner.
final class TextPointerCursorLiveTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false; executionTimeAllowance = 180 }

    @MainActor
    func testCoveredH1ParagraphAndHandles() throws {
        let library = try UITestLibrary.make(for: self)
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
        func check(_ name: String, _ expected: NSCursor) throws {
            let cursor = try XCTUnwrap(NSCursor.currentSystem, "Системный курсор недоступен")
            print("SYSTEM-CURSOR \(name): hotspot=\(cursor.hotSpot) size=\(cursor.image.size) expected=\(expected.hotSpot)/\(expected.image.size)")
            XCTAssertEqual(cursor.hotSpot, expected.hotSpot, name)
            XCTAssertEqual(cursor.image.size, expected.image.size, name)
        }
        for (name, y) in [("h1", title.maxY + 42), ("paragraph", title.maxY + 90), ("empty", title.maxY + 130)] {
            for step in 0..<12 {
                hover(CGPoint(x: title.minX + 12 + CGFloat(step) * 8, y: y))
                try check("\(name)-move-\(step)", .iBeam)
            }
            // Пока мышь стоит, ловим возврат стрелки после обновления tracking/cursor rects.
            for sample in 0..<20 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                try check("\(name)-still-\(sample)", .iBeam)
            }
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "text-cursor-\(name)"; shot.lifetime = .keepAlways; add(shot)
            if name != "empty" {
                XCTAssertTrue(app.blockDragHandle.waitForExistence(timeout: 3))
                let handle = app.blockDragHandle.frame
                hover(CGPoint(x: handle.midX, y: handle.midY))
                try check("\(name)-handle", .arrow)
            }
        }
    }
}
