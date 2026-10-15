import AppKit
import XCTest

/// US1 вживую (SC-004, SC-005): заметка переживает обычный выход и `kill -9` через 1,5 с после набора.
/// Сто циклов записи и открытия — в модульном тесте `SaveReopenCycleTests`.
final class NoteSurvivesRelaunchTests: XCTestCase {
    private var databaseURL: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        // Своя временная база: основная база Mac не трогается.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MyNotionUITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        databaseURL = folder.appendingPathComponent("MyNotion.sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
    }

    @MainActor
    func testNoteSurvivesQuitAndKillNine() throws {
        // Новая страница, название, абзац, выход.
        var app = launchApp()
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(app.textFields["page-title"].waitForExistence(timeout: 10))
        app.typeText("Список покупок")
        app.typeKey(.return, modifierFlags: [])
        app.typeText("Молоко, хлеб и сыр")
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10), "Приложение не вышло по ⌘Q")

        // Запуск — открыта та же страница с тем же текстом.
        app = launchApp()
        XCTAssertTrue(app.textViews["page-body"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields["page-title"].value as? String, "Список покупок")
        XCTAssertEqual(app.textViews["page-body"].value as? String, "Молоко, хлеб и сыр")

        // Дописать в конец и через 1,5 с — kill -9: ни выхода, ни записи при выходе.
        app.typeKey(.downArrow, modifierFlags: .command)
        app.typeText(" и яблоки")
        Thread.sleep(forTimeInterval: 1.5)
        try killNine(app)

        app = launchApp()
        XCTAssertTrue(app.textViews["page-body"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textViews["page-body"].value as? String, "Молоко, хлеб и сыр и яблоки")
        app.terminate()
    }

    @MainActor
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--database", databaseURL.path]
        app.launch()
        return app
    }

    /// Мгновенная остановка процесса сигналом SIGKILL, как `kill -9` в терминале.
    @MainActor
    private func killNine(_ app: XCUIApplication) throws {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "cloud.kurilov.mynotion")
        let pid = try XCTUnwrap(running.first?.processIdentifier, "Процесс приложения не найден")
        XCTAssertEqual(kill(pid, SIGKILL), 0, "kill -9 не прошёл: errno \(errno)")
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10), "Процесс не остановился после kill -9")
    }
}
