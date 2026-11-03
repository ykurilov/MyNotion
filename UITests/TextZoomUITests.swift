import XCTest

/// Масштаб текста страниц вживую: ⌘=, ⌘+, ⌘− и ⌘0 меняют текст и название открытой страницы, пункты — в меню «Вид»,
/// масштаб переживает перезапуск. Сами размеры, курсор, прокрутка и ⌘Z — `PageTextZoomTests`.
final class TextZoomUITests: XCTestCase {
    private var library: UITestLibrary!

    override func setUpWithError() throws {
        continueAfterFailure = false
        library = try UITestLibrary.make(for: self)
    }

    @MainActor
    func testShortcutsScaleOpenPageAndSurviveRelaunch() throws {
        var app = library.launchApp(appearance: "light")
        app.createPage(titled: "Масштаб")
        app.typeText("Заголовок")
        app.typeKey(.return, modifierFlags: [])
        app.typeText(String(repeating: "Обычный текст страницы, чтобы было видно размер. ", count: 6))
        let normal = settledTitleHeight(app)

        // Пункты меню «Вид».
        app.menuBars.menuBarItems["Вид"].click()
        for title in ["Увеличить текст", "Уменьшить текст", "Обычный размер текста"] {
            XCTAssertTrue(app.menuItems[title].waitForExistence(timeout: 5), "В «Вид» нет «\(title)»")
        }
        XCTAssertFalse(app.menuItems["Обычный размер текста"].isEnabled, "При 100 % «Обычный размер» должен быть выключен")
        app.typeKey(.escape, modifierFlags: [])

        // ⌘= и ⌘+ — по шагу вверх (115, 125), ⌘= ещё раз — 150 %.
        app.typeKey("=", modifierFlags: .command)
        XCTAssertTrue(waitForTitleHeight(app, normal * 1.15), "⌘= не увеличил: \(app.pageTitle.frame.height) от \(normal)")
        app.typeKey("+", modifierFlags: .command)
        XCTAssertTrue(waitForTitleHeight(app, normal * 1.25), "⌘+ не увеличил: \(app.pageTitle.frame.height) от \(normal)")
        app.typeKey("=", modifierFlags: .command)
        XCTAssertTrue(waitForTitleHeight(app, normal * 1.5), "Нет 150 %: \(app.pageTitle.frame.height) от \(normal)")
        attachSnapshot(of: app, named: "text-zoom-150")

        // Набор при 150 % — в ту же страницу.
        app.typeText("Ещё")
        // ⌘− — шаг вниз.
        app.typeKey("-", modifierFlags: .command)
        XCTAssertTrue(waitForTitleHeight(app, normal * 1.25), "⌘− не уменьшил: \(app.pageTitle.frame.height) от \(normal)")
        app.quit()

        // Перезапуск: масштаб на месте; ⌘0 — обычный размер (и в настройках — 100 % для других тестов).
        app = library.launchApp(appearance: "light", keepsTextZoom: true)
        XCTAssertTrue(app.pageTitle.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForTitleHeight(app, normal * 1.25), "Масштаб не пережил перезапуск: \(app.pageTitle.frame.height) от \(normal)")
        app.pageBody.click()
        app.typeKey("0", modifierFlags: .command)
        XCTAssertTrue(waitForTitleHeight(app, normal), "⌘0 не вернул обычный размер: \(app.pageTitle.frame.height) от \(normal)")
        XCTAssertTrue((app.pageBody.value as? String ?? "").contains("Ещё"), "Набранное при 150 % пропало")
        app.quit()
    }

    // MARK: Помощники

    @MainActor
    private func settledTitleHeight(_ app: XCUIApplication) -> CGFloat {
        XCTAssertTrue(app.pageTitle.waitForExistence(timeout: 5))
        return app.pageTitle.frame.height
    }

    /// Высота поля названия растёт со шрифтом; округление строк — в пределах 3 точек.
    @MainActor
    private func waitForTitleHeight(_ app: XCUIApplication, _ expected: CGFloat) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if abs(app.pageTitle.frame.height - expected) <= 3 { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    private func attachSnapshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
