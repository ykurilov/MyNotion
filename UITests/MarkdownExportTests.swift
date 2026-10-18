import XCTest

/// Выгрузка в Markdown (FR-017): ⌘⇧E → окно выбора папки (путь через ⌘⇧G) → «Выгрузить сюда» → карточка с кнопкой
/// «Показать в Finder» → папка выгрузки и файл страницы на месте.
final class MarkdownExportTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testExportFromMenuShortcutWritesFilesAndShowsNotice() throws {
        let library = try UITestLibrary.make(for: self)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyNotionExportTarget-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: destination) }

        let app = library.launchApp()
        app.createPage(titled: "Выгрузка")
        app.typeText("Привет, мир")

        app.typeKey("e", modifierFlags: [.command, .shift])
        let chooseButton = app.buttons["Выгрузить сюда"].firstMatch
        XCTAssertTrue(chooseButton.waitForExistence(timeout: 10), "Окно выбора папки не открылось по ⌘⇧E")

        // Путь папки — через «Перейти к папке» (⌘⇧G): окно выбора само мышью не листаешь.
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeText(destination.resolvingSymlinksInPath().path)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(chooseButton.waitForExistence(timeout: 5))
        // «Выгрузить сюда» — кнопка по умолчанию; щелчок по ней находит ещё и копию в Touch Bar.
        app.typeKey(.return, modifierFlags: [])

        let notice = app.descendants(matching: .any)["export-notice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 30), "Карточка выгрузки не появилась")
        let showInFinder = app.buttons["export-show-in-finder"]
        XCTAssertTrue(showInFinder.waitForExistence(timeout: 30), "Кнопки «Показать в Finder» нет. Карточка: \(notice.staticTexts.allElementsBoundByIndex.map(\.label))")

        let folders = try FileManager.default.contentsOfDirectory(atPath: destination.path)
            .filter { $0.hasPrefix("MyNotion-выгрузка-") }
        XCTAssertEqual(folders.count, 1, "Папка выгрузки не создалась: \(folders)")
        let exported = destination.appendingPathComponent(folders.first ?? "").appendingPathComponent("Выгрузка.md")
        let content = try String(contentsOf: exported, encoding: .utf8)
        XCTAssertTrue(content.hasPrefix("# Выгрузка"), "Заголовок страницы не в начале файла: \(content)")
        XCTAssertTrue(content.contains("Привет, мир"), "Текста страницы нет в файле: \(content)")

        app.buttons["export-close"].click()
        XCTAssertTrue(waitForAbsence(notice), "Карточка не закрылась")
        app.quit()
    }

    private func waitForAbsence(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }
}
