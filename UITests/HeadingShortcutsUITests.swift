import XCTest

/// ⌥⌘1…3 и ⌥⌘0 вживую: клавиши доходят до текста страницы мимо меню и вкладок. Логика — в HeadingShortcutsTests.
final class HeadingShortcutsUITests: XCTestCase {
    private var library: UITestLibrary!

    override func setUpWithError() throws {
        continueAfterFailure = false
        library = try UITestLibrary.make(for: self)
    }

    @MainActor
    func testOptionCommandDigitsTurnBlocksIntoHeadings() throws {
        let app = library.launchApp()
        app.createPage(titled: "Клавиши")
        app.typeText("раз")
        app.typeKey(.return, modifierFlags: [])
        app.typeText("два")
        app.typeKey("2", modifierFlags: [.command, .option])
        app.typeKey(.upArrow, modifierFlags: [])
        app.typeKey("1", modifierFlags: [.command, .option])
        app.typeText("!")
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey("0", modifierFlags: [.command, .option])
        app.typeKey(.upArrow, modifierFlags: [])
        app.typeKey("3", modifierFlags: [.command, .option])
        app.typeKey("z", modifierFlags: .command)
        app.quit()
        let expected: [UITestLibrary.SavedBlock] = [.init(kind: "heading1", text: "раз!"), .init(kind: "paragraph", text: "два")]
        XCTAssertEqual(try library.savedBlocks(ofPage: "Клавиши"), expected)
    }
}
