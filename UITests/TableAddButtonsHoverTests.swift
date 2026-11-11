import XCTest

/// «+» справа и снизу у простой таблицы: курсор в ячейке, мышь ведут к «+» — он остаётся виден и нажимается, как у Notion.
/// Новый столбец встаёт в прежнюю ширину таблицы.
final class TableAddButtonsHoverTests: XCTestCase {
    private var library: UITestLibrary!

    override func setUpWithError() throws {
        continueAfterFailure = false
        library = try UITestLibrary.make(for: self)
    }

    @MainActor
    func testPlusStaysVisibleUnderPointerAndAddsColumnAndRow() throws {
        let app = library.launchApp()
        app.createPage(titled: "Плюсы таблицы")
        app.typeText("/табл")
        XCTAssertTrue(app.popupItem("table").waitForExistence(timeout: 5), "Меню «/» не нашло таблицу")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.textViews["table-cell"].waitForExistence(timeout: 5), "Курсор не встал в ячейку")
        app.typeText("Имя")
        let table = app.descendants(matching: .any)["table"]
        let addColumn = app.descendants(matching: .any)["table-add-column"]
        let addRow = app.descendants(matching: .any)["table-add-row"]
        XCTAssertTrue(addColumn.waitForExistence(timeout: 5))

        for (name, button) in [("столбца", addColumn), ("строки", addRow)] {
            let before = table.frame
            table.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).hover()
            XCTAssertTrue(waitUntil { button.value as? String == "виден" }, "«+» \(name) не появился над таблицей")
            // Мышь — с таблицы на «+» по шагам, как рукой.
            let start = table.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            let startPoint = CGPoint(x: before.minX + before.width * 0.5, y: before.minY + before.height * 0.3)
            let target = CGPoint(x: button.frame.midX, y: button.frame.midY)
            for step in 1...8 {
                let t = CGFloat(step) / 8
                start.withOffset(CGVector(dx: (target.x - startPoint.x) * t, dy: (target.y - startPoint.y) * t)).hover()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            let shot = XCTAttachment(screenshot: table.screenshot())
            shot.name = "table-plus-\(name)-hovered"
            shot.lifetime = .keepAlways
            add(shot)
            XCTAssertEqual(button.value as? String, "виден", "«+» \(name) исчез под мышью")
            let size = table.value as? String
            button.click()
            XCTAssertEqual(button.value as? String, "виден", "«+» \(name) исчез после нажатия")
            XCTAssertTrue(waitUntil { table.value as? String != size }, "Нажатие «+» \(name) ничего не добавило: \(size ?? "")")
            if button == addColumn {
                // Новый столбец встаёт в прежнюю ширину таблицы: остальные ужимаются.
                XCTAssertEqual(table.frame.width, before.width, accuracy: 1, "Таблица расширилась от нового столбца")
            }
        }
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
