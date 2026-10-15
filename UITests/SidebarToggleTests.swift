import XCTest

/// Шторка боковой панели и «✎» в верхней строке, как в Notion (contracts/editor-interactions.md, ⌘⌥S):
/// кнопка у светофора сворачивает и разворачивает панель, ⌘⌥S и пункт меню «Вид» — то же,
/// свёрнутая панель остаётся свёрнутой после перезапуска.
final class SidebarToggleTests: XCTestCase {
    private var library: UITestLibrary!

    override func setUpWithError() throws {
        continueAfterFailure = false
        library = try UITestLibrary.make(for: self)
    }

    @MainActor
    func testToggleCollapsesExpandsAndSurvivesRelaunch() throws {
        var app = launch()
        app.createPage(titled: "Входящие")
        let tree = app.outlines["page-tree"]
        let toggle = app.buttons["sidebar-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))

        // Кнопка — в строке светофора: середина на 90 от левого края окна и на 16 от верха (visual-style.md).
        let window = app.windows.firstMatch.frame
        XCTAssertEqual(toggle.frame.midX - window.minX, 90, accuracy: 2)
        XCTAssertEqual(toggle.frame.midY - window.minY, 16, accuracy: 2)
        let togglePlace = toggle.frame

        // Кнопкой: свернуть — дерево ушло, кнопка на том же месте; развернуть — дерево вернулось.
        toggle.click()
        XCTAssertTrue(waitUntilGone(tree), "Панель не свернулась по кнопке")
        XCTAssertEqual(toggle.frame.origin.x, togglePlace.origin.x, accuracy: 1)
        XCTAssertEqual(toggle.frame.origin.y, togglePlace.origin.y, accuracy: 1)
        XCTAssertTrue(app.textFields["page-title"].exists, "Страница должна остаться на экране")
        toggle.click()
        XCTAssertTrue(tree.waitForExistence(timeout: 5), "Панель не развернулась по кнопке")

        // Пункт меню «Вид» — на месте и называет следующее действие.
        let menuNames = app.menuBars.menuBarItems.allElementsBoundByIndex.map(\.title)
        app.menuBars.menuBarItems["Вид"].click()
        let viewItems = app.menuBars.menuBarItems["Вид"].menuItems.allElementsBoundByIndex.map(\.title)
        XCTAssertTrue(app.menuItems["Скрыть боковую панель"].waitForExistence(timeout: 5),
                      "меню: \(menuNames), «Вид»: \(viewItems)")
        app.typeKey(.escape, modifierFlags: [])

        // ⌘⌥S — то же, что кнопка.
        app.typeKey("s", modifierFlags: [.command, .option])
        XCTAssertTrue(waitUntilGone(tree), "Панель не свернулась по ⌘⌥S")
        app.menuBars.menuBarItems["Вид"].click()
        XCTAssertTrue(app.menuItems["Показать боковую панель"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])

        // Перезапуск: панель по-прежнему свёрнута, кнопка на месте; ⌘⌥S разворачивает.
        app.quit()
        app = launch()
        XCTAssertTrue(app.buttons["sidebar-toggle"].waitForExistence(timeout: 10))
        XCTAssertFalse(tree.exists, "Свёрнутая панель развернулась после перезапуска")
        app.typeKey("s", modifierFlags: [.command, .option])
        XCTAssertTrue(app.outlines["page-tree"].waitForExistence(timeout: 5), "Панель не развернулась по ⌘⌥S")
        app.menuBars.menuBarItems["Вид"].click()
        XCTAssertTrue(app.menuItems["Скрыть боковую панель"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        app.terminate()
    }

    @MainActor
    func testNewPageButtonCreatesPageLikeCommandN() throws {
        let app = launch()
        app.createPage(titled: "Первая")
        let newPage = app.buttons["sidebar-new-page"]
        XCTAssertTrue(newPage.waitForExistence(timeout: 5))
        XCTAssertLessThan(abs(newPage.frame.midY - app.buttons["sidebar-toggle"].frame.midY), 2,
                          "«✎» не в строке со шторкой")
        let rowsBefore = app.outlines["page-tree"].outlineRows.count
        newPage.click()
        // Как ⌘N: новая строка в дереве, курсор в названии новой страницы.
        let title = app.textFields["page-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        app.typeText("Вторая")
        XCTAssertTrue(app.outlines["page-tree"].staticTexts["Вторая"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.outlines["page-tree"].outlineRows.count, rowsBefore + 1)
        app.terminate()
    }

    // MARK: Помощники

    @MainActor
    private func launch() -> XCUIApplication {
        let app = library.launchApp()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        return app
    }

    private func waitUntilGone(_ element: XCUIElement) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter().wait(for: [gone], timeout: 5) == .completed
    }
}
