import XCTest

/// FR-032 вживую: Shift+Enter переносит строку внутри блока, Enter создаёт новый блок; блок с переносом
/// перетаскивается за «⋮⋮» целиком и после перезапуска остаётся одним блоком.
/// Логика переноса проверена модульными тестами `SoftLineBreakTests`; здесь — что части работают вместе.
final class SoftLineBreakTests: XCTestCase {
    private var library: UITestLibrary!
    /// Перенос строки внутри блока на странице — разрыв строки U+2028.
    private let lineBreak = "\u{2028}"

    override func setUpWithError() throws {
        continueAfterFailure = false
        library = try UITestLibrary.make(for: self)
    }

    @MainActor
    func testShiftReturnBreaksLineAndBlockMovesWholeAcrossRelaunch() throws {
        var app = library.launchApp()
        app.createPage(titled: "Переносы")
        app.typeText("раз")
        app.typeKey(.return, modifierFlags: .shift)
        app.typeText("полтора")
        app.typeKey(.return, modifierFlags: [])
        app.typeText("два")
        app.typeKey(.return, modifierFlags: [])
        app.typeText("три")
        XCTAssertEqual(app.pageBody.value as? String, "раз\(lineBreak)полтора\nдва\nтри", "Shift+Enter не перенёс строку внутри блока")

        // Тянуть блок в две строки за «⋮⋮» ниже последнего блока: едет целиком.
        XCTAssertTrue(app.hoverFirstBlock(), "Ручки блока не появились при наведении")
        let handle = app.blockDragHandle
        let grip = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        grip.click(forDuration: 0.3, thenDragTo: grip.withOffset(CGVector(dx: 0, dy: handle.frame.height * 6)))
        XCTAssertEqual(app.pageBody.value as? String, "два\nтри\nраз\(lineBreak)полтора", "Блок с переносом переставился не целиком")

        app.quit()
        XCTAssertEqual(try library.savedBlocks(ofPage: "Переносы").map(\.text), ["два", "три", "раз\nполтора"])

        app = library.launchApp()
        XCTAssertTrue(app.pageBody.waitForExistence(timeout: 10))
        XCTAssertEqual(app.pageBody.value as? String, "два\nтри\nраз\(lineBreak)полтора", "После перезапуска перенос не тот")
        app.terminate()
    }
}
