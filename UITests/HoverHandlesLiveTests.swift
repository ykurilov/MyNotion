import AppKit
import XCTest

/// Реальное OS-наведение без набора: координаты от окна, а не от AX-рамки длинного документа.
final class HoverHandlesLiveTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 180
    }

    @MainActor
    func testNativeHoverShowsHandlesOnHeadingAndParagraph() throws {
        let library = try EditorScenarioFixture.library(for: self)
        let app = library.launchApp(appearance: "light")
        app.activate()
        addTeardownBlock { @MainActor in app.terminate() }
        XCTAssertTrue(app.pageTitle.waitForExistence(timeout: 10))
        app.pageTitle.click() // Каретка вне body; автокоррекции и набора перед hover нет.
        let window = app.windows.firstMatch
        let title = app.pageTitle.frame
        let x = title.minX + 80
        let origin = window.coordinate(withNormalizedOffset: .zero)
        for (name, y) in [("heading", title.maxY + 34), ("paragraph", title.maxY + 74)] {
            origin.withOffset(CGVector(dx: 50, dy: 50)).hover()
            origin.withOffset(CGVector(dx: x - window.frame.minX, dy: y - window.frame.minY)).hover()
            let mouse = NSEvent.mouseLocation
            let screenTop = try XCTUnwrap(NSScreen.screens.first).frame.maxY
            print("NATIVE-HOVER \(name): target=\(x),\(y) actual=\(mouse.x),\(screenTop - mouse.y) window=\(window.frame)")
            XCTAssertEqual(mouse.x, x, accuracy: 2)
            XCTAssertEqual(screenTop - mouse.y, y, accuracy: 2)
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "native-hover-\(name)"
            shot.lifetime = .keepAlways
            add(shot)
            XCTAssertTrue(app.blockDragHandle.waitForExistence(timeout: 3), "Ручки не появились над \(name)")
            XCTAssertTrue(app.blockDragHandle.isHittable)
            let handle = app.blockDragHandle.frame
            print("NATIVE-HOVER \(name): handle=\(handle)")
            let region = CGRect(x: title.minX, y: handle.midY - 20, width: 500, height: 40)
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            let baseline = window.screenshot()
            for step in 1...16 {
                let point = CGPoint(x: x + CGFloat(step) * 10, y: y + CGFloat(step % 3 - 1) * 3)
                origin.withOffset(CGVector(dx: point.x - window.frame.minX, dy: point.y - window.frame.minY)).hover()
                let current = window.screenshot()
                let diff = HoverScreenshotComparison.changedPixels(baseline, current, rect: region, window: window.frame)
                print("NATIVE-SLOW \(name) step=\(step) pixels=\(diff) handle=\(app.blockDragHandle.frame)")
                XCTAssertEqual(diff, 0, "Наведение изменило текст \(name), шаг \(step)")
                XCTAssertEqual(app.blockDragHandle.frame.minY, handle.minY, accuracy: 1)
                XCTAssertTrue(app.blockDragHandle.isHittable)
                if step == 16 {
                    let end = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                    end.name = "native-slow-\(name)-end"
                    end.lifetime = .keepAlways
                    add(end)
                }
            }
            origin.withOffset(CGVector(dx: x - window.frame.minX, dy: y - window.frame.minY)).doubleClick()
            let selected = window.screenshot()
            let control = HoverScreenshotComparison.changedPixels(baseline, selected, rect: region, window: window.frame)
            print("NATIVE-CONTROL \(name) pixels=\(control)")
            XCTAssertGreaterThan(control, 0, "Сравниваемая область не увидела выделение слова")
            app.pageTitle.click()

        }
    }
}
