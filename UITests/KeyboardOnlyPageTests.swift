import XCTest

/// Страница только с клавиатуры (SC-006, contracts/editor-interactions.md): ⌘N, название, Enter,
/// заголовок через `# `, три пункта через `- ` — без мыши и не дольше 10 с.
final class KeyboardOnlyPageTests: XCTestCase {
    @MainActor
    func testPageWithHeadingAndListFromKeyboardOnly() throws {
        continueAfterFailure = false
        let library = try UITestLibrary.make(for: self)
        let app = library.launchApp()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        let start = Date()
        app.createPage(titled: "Поездка")
        app.typeText("# Сборы")
        app.typeKey(.return, modifierFlags: [])
        app.typeText("- паспорт")
        app.typeKey(.return, modifierFlags: [])
        app.typeText("билеты")
        app.typeKey(.return, modifierFlags: [])
        app.typeText("зарядка")
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(app.pageBody.value as? String, "Сборы\nпаспорт\nбилеты\nзарядка", "Быстрые символы не попадают в текст")
        XCTAssertLessThanOrEqual(elapsed, 10, "Страница с клавиатуры дольше 10 с")
        add(XCTAttachment(string: String(format: "Страница с клавиатуры: %.1f с", elapsed)))

        app.quit()
        XCTAssertEqual(try library.savedBlocks(ofPage: "Поездка"), [
            .init(kind: "heading1", text: "Сборы"),
            .init(kind: "bulletItem", text: "паспорт"),
            .init(kind: "bulletItem", text: "билеты"),
            .init(kind: "bulletItem", text: "зарядка"),
        ])
    }
}
