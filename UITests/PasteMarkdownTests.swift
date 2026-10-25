import AppKit
import XCTest

/// Вставка ⌘V ответа ИИ в Markdown вживую: заголовок, список, жирный — блоками, одна ⌘Z убирает всё.
/// Разбор и слияние с абзацем проверены модульными тестами `PastedTextTests` и `PasteBlocksTests`.
final class PasteMarkdownTests: XCTestCase {
    private var library: UITestLibrary!

    override func setUpWithError() throws {
        continueAfterFailure = false
        library = try UITestLibrary.make(for: self)
    }

    @MainActor
    func testPastingMarkdownMakesHeadingListAndBold() throws {
        let app = library.launchApp()
        app.createPage(titled: "Вставка")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("## План\n\nСначала **главное**:\n\n- первый\n- второй\n", forType: .string)
        app.typeKey("v", modifierFlags: .command)
        XCTAssertTrue(waitUntil { app.pageBody.value as? String == "План\nСначала главное:\nпервый\nвторой" },
                      "Markdown не стал блоками: \(app.pageBody.value ?? "")")

        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(waitUntil { (app.pageBody.value as? String)?.isEmpty == true }, "⌘Z убрала не всю вставку: \(app.pageBody.value ?? "")")
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitUntil { app.pageBody.value as? String == "План\nСначала главное:\nпервый\nвторой" })

        app.quit()
        XCTAssertEqual(try library.savedBlocks(ofPage: "Вставка").map(\.kind), ["heading2", "paragraph", "bulletItem", "bulletItem"])
        XCTAssertTrue(try library.savedTextStyles(ofPage: "Вставка")[1].contains("bold"), "Нет жирного")
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }
}
