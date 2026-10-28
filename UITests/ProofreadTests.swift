import AppKit
import XCTest

/// «Исправить ошибки» вживую с подменным исправителем (`--fake-proofreader`: без сети и ключа):
/// выделил текст → кнопка в панели → окно правок → «Заменить» → ⌘Z возвращает; Esc в окне правок — «Отмена».
/// Сценарий — в светлой теме; тёмная — только снимок окна правок.
/// Сравнение, перенос оформления и ошибки проверены модульными тестами `ProofreadingTests` и `ProofreadTests`.
final class ProofreadTests: XCTestCase {
    private var library: UITestLibrary!

    override func setUpWithError() throws {
        continueAfterFailure = false
        library = try UITestLibrary.make(for: self)
    }

    @MainActor
    func testProofreadReplaceAndUndo() throws {
        let app = library.launchApp(appearance: "light", arguments: ["--fake-proofreader"])
        app.createPage(titled: "Ошибки")
        app.typeText("превет всем, как дила")
        app.typeKey(.leftArrow, modifierFlags: [.command, .shift])

        let button = app.descendants(matching: .any)["format-proofread"]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "В панели нет «Исправить ошибки»")
        button.click()
        let replace = app.descendants(matching: .any)["proofread-replace"]
        XCTAssertTrue(replace.waitForExistence(timeout: 10), "Окно правок не показало «Заменить»")
        attachSnapshot(of: app, named: "grammar-light")

        replace.click()
        XCTAssertTrue(replace.waitForNonExistence(timeout: 5), "Окно правок не закрылось")
        XCTAssertEqual(app.pageBody.value as? String, "привет всем, как дела")

        app.typeKey("z", modifierFlags: .command)
        XCTAssertEqual(app.pageBody.value as? String, "превет всем, как дила", "⌘Z не вернул текст одним шагом")

        // Esc — «Отмена»: окно закрывается, текст прежний.
        app.typeKey(.rightArrow, modifierFlags: .command)
        app.typeKey(.leftArrow, modifierFlags: [.command, .shift])
        XCTAssertTrue(button.waitForExistence(timeout: 5), "Панель не всплыла над выделением")
        button.click()
        XCTAssertTrue(replace.waitForExistence(timeout: 10), "Окно правок не открылось второй раз")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(replace.waitForNonExistence(timeout: 5), "Esc не закрыл окно правок")
        XCTAssertEqual(app.pageBody.value as? String, "превет всем, как дила")
        app.quit()
    }

    @MainActor
    func testProofreadPanelDark() throws {
        let app = library.launchApp(appearance: "dark", arguments: ["--fake-proofreader"])
        app.createPage(titled: "Ошибки")
        app.typeText("превет всем, как дила")
        app.typeKey(.leftArrow, modifierFlags: [.command, .shift])
        let button = app.descendants(matching: .any)["format-proofread"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.click()
        XCTAssertTrue(app.descendants(matching: .any)["proofread-replace"].waitForExistence(timeout: 10))
        attachSnapshot(of: app, named: "grammar-dark")
        app.quit()
    }

    private func attachSnapshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
