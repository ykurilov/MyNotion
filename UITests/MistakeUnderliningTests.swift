import XCTest

/// «Подчёркивать ошибки» вживую: страница с опечатками подчёркнута, флажок в Настройках снимает подчёркивания
/// в открытом окне сразу, без перезапуска. Снимки до и после. Само применение настройки — `MistakeUnderliningTests`.
final class MistakeUnderliningUITests: XCTestCase {
    private var library: UITestLibrary!

    override func setUpWithError() throws {
        continueAfterFailure = false
        library = try UITestLibrary.make(for: self)
    }

    @MainActor
    func testSwitchingOffRemovesUnderlinesInOpenPage() throws {
        let app = library.launchApp(appearance: "light")
        app.createPage(titled: "Опечатки")
        app.typeText("превет всем, как дила, сколко лет ")
        settle()
        attachSnapshot(of: app, named: "grammar-underline-on")

        setUnderlining(false, in: app)
        app.pageBody.click()
        app.typeKey(.rightArrow, modifierFlags: .command)
        settle()
        attachSnapshot(of: app, named: "grammar-underline-off")

        // Настройка сохраняется в общих настройках приложения — вернуть, чтобы не мешать другим тестам.
        setUnderlining(true, in: app)
        app.quit()
    }

    private func setUnderlining(_ isOn: Bool, in app: XCUIApplication) {
        app.typeKey(",", modifierFlags: .command)
        let toggle = app.checkBoxes["underline-mistakes"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "В Настройках нет «Подчёркивать ошибки»")
        XCTAssertEqual(toggle.value as? Int, isOn ? 0 : 1)
        toggle.click()
        XCTAssertEqual(toggle.value as? Int, isOn ? 1 : 0)
        app.buttons["sync-settings-done"].click()
        XCTAssertTrue(toggle.waitForNonExistence(timeout: 5), "Настройки не закрылись")
    }

    /// Проверка орфографии macOS рисует подчёркивания с задержкой; дождаться её перед снимком.
    private func settle() {
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "проверка орфографии")], timeout: 2)
    }

    private func attachSnapshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
