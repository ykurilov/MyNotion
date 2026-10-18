import XCTest

/// Поиск страницы по слову (US4, сценарий 4.1): ⇧⌘F ставит курсор в поле поиска боковой панели, ввод показывает
/// выдачу, ↓ выбирает следующую строку, Enter открывает страницу, поле очищается и выдача закрывается.
final class PageSearchUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testFindPageByWordAndOpenWithKeyboard() throws {
        let library = try UITestLibrary.make(for: self)
        let app = library.launchApp()
        app.createPage(titled: "Альфа")
        app.typeText("общее слово в тексте")
        app.createPage(titled: "Бета")
        app.typeText("общее слово тоже")
        // Переход на новую страницу записывает набранное в прежней.
        app.createPage(titled: "Гамма")

        app.typeKey("f", modifierFlags: [.command, .shift])
        let field = app.textFields["sidebar-search"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Нет поля поиска")
        app.typeText("общ")

        let results = app.descendants(matching: .any)["search-results-list"]
        XCTAssertTrue(results.waitForExistence(timeout: 5), "Выдача не появилась")
        XCTAssertTrue(waitFor(results) { $0.contains("Альфа") && $0.contains("Бета") }, "В выдаче: \(results.label)")
        XCTAssertFalse(results.label.contains("Гамма"), "Страница без слова в выдаче: \(results.label)")
        let titles = results.label.components(separatedBy: ", ")
        XCTAssertEqual(titles.count, 2, "В выдаче: \(results.label)")

        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(waitFor(app.pageTitle) { _ in (app.pageTitle.value as? String) == titles[1] },
                      "Открылась «\(app.pageTitle.value ?? "")», ждали «\(titles[1])»")
        XCTAssertTrue(waitFor(results, gone: true), "Выдача не закрылась")
        XCTAssertEqual(field.value as? String ?? "", "", "Поле поиска не очистилось")
    }

    @MainActor
    private func waitFor(_ element: XCUIElement, gone: Bool = false, _ condition: (String) -> Bool = { _ in true }) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if gone ? !element.exists : element.exists && condition(element.label) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }
}
