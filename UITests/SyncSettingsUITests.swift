import XCTest

/// Настройки синхронизации вживую (проверка интерфейса, раунд 4, № 2, 7, 9): поля на одной левой линии и одной высоты,
/// в надписях и на кнопках нет слов разработчика.
final class SyncSettingsUITests: XCTestCase {
    private var library: UITestLibrary!

    override func setUpWithError() throws {
        continueAfterFailure = false
        library = try UITestLibrary.make(for: self)
    }

    @MainActor
    func testSettingsSpeakPlainLanguageAndFieldsLineUp() throws {
        let app = library.launchApp()
        XCTAssertTrue(app.pageBody.waitForExistence(timeout: 10) || app.windows.firstMatch.waitForExistence(timeout: 10))
        app.typeKey(",", modifierFlags: .command)

        let name = app.textFields["sync-device-name"]
        let code = app.textFields["sync-join-code"]
        XCTAssertTrue(name.waitForExistence(timeout: 10), "Окно настроек не открылось")
        XCTAssertTrue(code.exists)
        XCTAssertEqual(name.frame.minX, code.frame.minX, accuracy: 0.5, "Поля начинаются не на одной линии")
        XCTAssertEqual(name.frame.height, code.frame.height, accuracy: 0.5, "Поля разной высоты")
        XCTAssertEqual(name.frame.maxX, code.frame.maxX, accuracy: 0.5, "Поля кончаются не на одной линии")

        let settings = app.descendants(matching: .any)["sync-settings"]
        let texts = settings.staticTexts.allElementsBoundByIndex.map { ($0.value as? String) ?? $0.label }
            + settings.buttons.allElementsBoundByIndex.map(\.label)
        XCTAssertGreaterThan(texts.count, 4, "Надписей не видно: \(texts)")
        for text in texts {
            for word in ["токен", "сервер", "пачк", "журнал", "шифр", "устройств"] {
                XCTAssertFalse(text.localizedCaseInsensitiveContains(word), "«\(word)» в «\(text)»")
            }
        }
        XCTAssertTrue(settings.buttons["Подключить Mac"].exists, "Нет кнопки «Подключить Mac»: \(texts)")
    }
}
