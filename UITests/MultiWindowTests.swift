import XCTest

/// FR-029 и крайний случай spec «Второе окно приложения»: одна страница в двух окнах, набор в обоих —
/// текст общий, без конфликта и без потерь, после перезапуска на месте.
final class MultiWindowTests: XCTestCase {
    private var library: UITestLibrary!

    override func setUpWithError() throws {
        continueAfterFailure = false
        library = try UITestLibrary.make(for: self)
    }

    @MainActor
    func testSamePageInTwoWindowsSharesText() throws {
        var app = library.launchApp()
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(app.textFields["page-title"].waitForExistence(timeout: 10))
        app.typeText("Общая")
        app.typeKey(.return, modifierFlags: [])
        app.typeText("раз")

        // «Файл → Новое окно» (⌥⌘N): второе окно с той же страницей, курсор в её тексте.
        app.typeKey("n", modifierFlags: [.command, .option])
        let bodies = app.textViews.matching(identifier: "page-body")
        XCTAssertTrue(waitFor { bodies.count == 2 }, "Второе окно не открылось: страниц на экране \(bodies.count)")
        XCTAssertEqual(app.textFields.matching(identifier: "page-title").allElementsBoundByIndex.compactMap { $0.value as? String },
                       ["Общая", "Общая"])
        XCTAssertTrue(waitFor { texts(bodies) == ["раз", "раз"] }, "Тексты окон: \(texts(bodies))")

        // Набор во втором окне виден в первом.
        app.typeKey(.downArrow, modifierFlags: .command)
        app.typeText(" два")
        XCTAssertTrue(waitFor { texts(bodies) == ["раз два", "раз два"] }, "Тексты окон: \(texts(bodies))")

        // И обратно: ⌘` — к первому окну, набор там виден во втором.
        app.typeKey("`", modifierFlags: .command)
        app.typeKey(.downArrow, modifierFlags: .command)
        app.typeText(" три")
        XCTAssertTrue(waitFor { texts(bodies) == ["раз два три", "раз два три"] }, "Тексты окон: \(texts(bodies))")

        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10), "Приложение не вышло по ⌘Q")
        XCTAssertEqual(try library.savedBlocks(ofPage: "Общая").map(\.text), ["раз два три"])

        app = library.launchApp()
        XCTAssertTrue(app.textViews["page-body"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textViews["page-body"].value as? String, "раз два три")
        app.terminate()
    }

    @MainActor
    private func texts(_ bodies: XCUIElementQuery) -> [String] {
        bodies.allElementsBoundByIndex.map { $0.value as? String ?? "" }
    }

    @MainActor
    private func waitFor(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }
}
