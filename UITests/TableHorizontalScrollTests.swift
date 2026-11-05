import XCTest

/// Широкая простая таблица, как у Notion: прокручивается вбок внутри себя, страница не уезжает;
/// границу столбца в прокрученной части тянут мышью.
final class TableHorizontalScrollTests: XCTestCase {
    private var library: UITestLibrary!

    override func setUpWithError() throws {
        continueAfterFailure = false
        library = try UITestLibrary.make(for: self)
    }

    @MainActor
    func testWideTableScrollsSidewaysAndResizesScrolledColumn() throws {
        let app = library.launchApp()
        app.createPage(titled: "Широкая таблица")
        app.typeText("/табл")
        XCTAssertTrue(app.popupItem("table").waitForExistence(timeout: 5), "Меню «/» не нашло таблицу")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.textViews["table-cell"].waitForExistence(timeout: 5), "Курсор не встал в ячейку")
        app.typeText("Имя")
        let table = app.descendants(matching: .any)["table"]
        let scroll = app.descendants(matching: .any)["table-scroll"]
        let addColumn = app.descendants(matching: .any)["table-add-column"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        let window = app.windows.firstMatch.frame
        let scrollLeft = scroll.frame.minX

        // Четыре столбца по 120 справа: сетка шире места до края окна.
        for _ in 0..<4 {
            let width = table.frame.width
            scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.3)).hover()
            XCTAssertTrue(waitUntil { addColumn.value as? String == "виден" }, "«+» столбца не появился")
            if addColumn.frame.maxX > scroll.frame.maxX {
                scroll.scroll(byDeltaX: -2000, deltaY: 0)
                RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            }
            addColumn.click()
            XCTAssertTrue(waitUntil { table.frame.width > width + 100 }, "«+» столбца ничего не добавил")
        }
        XCTAssertEqual(scroll.frame.minX, scrollLeft, accuracy: 1, "Левый край таблицы сдвинулся")
        XCTAssertLessThanOrEqual(scroll.frame.maxX, window.maxX + 1, "Таблица ушла за край окна")
        XCTAssertGreaterThan(table.frame.width, scroll.frame.width + 100, "Сетка не шире видимой части")

        // Жест вбок над таблицей: прокручивается сетка, а не страница.
        scroll.scroll(byDeltaX: 2000, deltaY: 0)
        XCTAssertTrue(waitUntil { abs(table.frame.minX - scroll.frame.minX) < 1 }, "Таблица не вернулась к началу")
        scroll.scroll(byDeltaX: -2000, deltaY: 0)
        XCTAssertTrue(waitUntil { table.frame.maxX < scroll.frame.maxX + 1 && table.frame.minX < scroll.frame.minX - 100 },
                      "Таблица не прокрутилась к концу: \(table.frame) в \(scroll.frame)")
        XCTAssertEqual(scroll.frame.minX, scrollLeft, accuracy: 1, "Страница уехала вбок")
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = "table-scrolled-to-end"
        shot.lifetime = .keepAlways
        add(shot)

        // Правая граница последнего столбца — у конца сетки, левее «+» (4 + 18) и линии 1.
        let width = table.frame.width
        let boundaryX = table.frame.width - 22 - 0.5
        let boundary = table.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: boundaryX, dy: 20))
        boundary.hover()
        boundary.click(forDuration: 0.3, thenDragTo: boundary.withOffset(CGVector(dx: -50, dy: 0)), withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertTrue(waitUntil { abs(table.frame.width - (width - 50)) < 4 },
                      "Протяжка границы в прокрученной части не сузила столбец: было \(width), стало \(table.frame.width)")
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }
}
