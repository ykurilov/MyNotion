import XCTest

/// Иконка страницы, как в Notion (FR-034): «Добавить иконку» при наведении на шапку, выбор в окне эмодзи поиском,
/// ⌘Z, иконка в боковой панели и в пути, на месте после перезапуска; из боковой панели — то же окно, «Убрать».
final class PageIconTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testChooseIconSurvivesRelaunchAndRemove() throws {
        let library = try UITestLibrary.make(for: self)
        var app = library.launchApp()
        app.createPage(titled: "Иконка")

        // Без иконки «Добавить иконку» появляется только под мышью над шапкой и ставит случайную.
        let addIcon = app.descendants(matching: .any)["add-page-icon"]
        app.outlines["page-tree"].outlineRows.firstMatch.hover()
        XCTAssertTrue(waitForAbsence(addIcon), "«Добавить иконку» видна, когда мышь не над шапкой")
        app.pageTitle.hover()
        XCTAssertTrue(addIcon.waitForExistence(timeout: 5), "«Добавить иконку» не появилась при наведении")
        addIcon.click()
        let icon = app.descendants(matching: .any)["page-icon"]
        XCTAssertTrue(icon.waitForExistence(timeout: 5), "Иконка не поставилась")
        let random = icon.label

        // Щелчок по иконке — окно выбора, поиск по-русски, Enter ставит найденное.
        icon.click()
        let search = app.descendants(matching: .any)["emoji-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5), "Окно выбора не открылось")
        app.typeText("синяя книга")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitFor(icon, label: "📘"), "Иконка: \(icon.label)")
        XCTAssertFalse(search.exists, "Окно выбора не закрылось")
        XCTAssertTrue(sidebarIcon(app, "📘").waitForExistence(timeout: 5), "В боковой панели нет иконки")
        let breadcrumb = app.descendants(matching: .any)["page-breadcrumb"]
        XCTAssertTrue(breadcrumbText(breadcrumb).contains("📘"), "В пути нет иконки: \(breadcrumbText(breadcrumb))")

        // ⌘Z возвращает прежнюю, ⇧⌘Z — снова выбранную.
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(waitFor(icon, label: random), "⌘Z не вернул прежнюю иконку: \(icon.label)")
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitFor(icon, label: "📘"), "⇧⌘Z не вернул выбранную: \(icon.label)")

        // После перезапуска — на месте.
        app.quit()
        XCTAssertEqual(try library.savedIcon(ofPage: "Иконка"), "📘")
        app = library.launchApp()
        XCTAssertTrue(icon.waitForExistence(timeout: 10))
        XCTAssertEqual(icon.label, "📘")
        XCTAssertTrue(sidebarIcon(app, "📘").waitForExistence(timeout: 5))

        // Из боковой панели — то же окно; «Убрать» снимает иконку.
        let row = app.outlines["page-tree"].outlineRows.containing(NSPredicate(format: "value == %@", "Иконка")).firstMatch
        let rowIcon = row.descendants(matching: .any)["page-tree-icon"]
        XCTAssertTrue(rowIcon.waitForExistence(timeout: 5), "У строки нет кнопки иконки")
        rowIcon.click()
        let remove = app.descendants(matching: .any)["emoji-remove"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5), "Окно выбора из боковой панели не открылось")
        remove.click()
        XCTAssertTrue(waitForAbsence(icon), "Иконка не убралась из шапки")
        XCTAssertFalse(sidebarIcon(app, "📘").exists, "Иконка осталась в боковой панели")
        app.quit()
        XCTAssertNil(try library.savedIcon(ofPage: "Иконка"))
    }

    @MainActor
    private func sidebarIcon(_ app: XCUIApplication, _ emoji: String) -> XCUIElement {
        app.outlines["page-tree"].staticTexts.matching(NSPredicate(format: "value == %@", emoji)).firstMatch
    }

    @MainActor
    private func breadcrumbText(_ element: XCUIElement) -> String {
        element.label + ((element.value as? String) ?? "")
    }

    @MainActor
    private func waitFor(_ element: XCUIElement, label: String) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if element.exists, element.label == label { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    @MainActor
    private func waitForAbsence(_ element: XCUIElement) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if !element.exists { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }
}
