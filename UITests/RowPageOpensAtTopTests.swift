import XCTest

/// Страница строки открывается сверху (T112, сверка с Notion): база прокручена далеко вниз, строка открыта на всю страницу —
/// название строки на месте и выше свойств, а не уехало за верх окна.
final class RowPageOpensAtTopTests: XCTestCase {
    private var library: UITestLibrary!

    override func setUpWithError() throws {
        continueAfterFailure = false
        library = try UITestLibrary.make(for: self)
    }

    @MainActor
    func testRowOpenedFromMiddleOfLongDatabaseShowsTitleAtTop() throws {
        let app = library.launchApp(arguments: ["--generate-004-sample"])
        let tasks = app.outlines["page-tree"].outlineRows.containing(NSPredicate(format: "value == %@", "Задачи")).firstMatch
        XCTAssertTrue(tasks.waitForExistence(timeout: 120), "Эталона «Задачи» нет в дереве")
        tasks.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        let grid = app.descendants(matching: .any).matching(identifier: "database-grid").element(boundBy: 0)
        XCTAssertTrue(grid.waitForExistence(timeout: 20), "Таблица не открылась")

        // Прокрутка далеко вниз, строка под мышью — «ОТКРЫТЬ» → просмотр сбоку → «на всю страницу».
        grid.scroll(byDeltaX: 0, deltaY: -4000)
        // Таблица выше окна: наводим на строку в видимой середине окна, у названия.
        app.windows.firstMatch.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 420, dy: 400)).hover()
        let open = app.buttons["database-row-open"]
        XCTAssertTrue(open.waitForExistence(timeout: 5), "Нет «ОТКРЫТЬ» при наведении")
        open.click()
        let expand = app.descendants(matching: .any)["row-peek-expand"]
        XCTAssertTrue(expand.waitForExistence(timeout: 5), "Строка не открылась сбоку")
        expand.click()

        let title = app.descendants(matching: .any)["page-title"].firstMatch
        let properties = app.descendants(matching: .any)["row-properties"].firstMatch
        XCTAssertTrue(properties.waitForExistence(timeout: 5), "Нет свойств строки")
        XCTAssertTrue(title.waitForExistence(timeout: 5), "Нет названия строки")
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(title.frame.minY, window.minY, "Название строки уехало за верх окна: \(title.frame) в \(window)")
        XCTAssertLessThanOrEqual(title.frame.maxY, properties.frame.minY + 1, "Свойства выше названия: \(title.frame) / \(properties.frame)")
        app.quit()
    }
}
