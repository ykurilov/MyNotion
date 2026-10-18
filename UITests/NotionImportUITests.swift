import XCTest

/// Импорт из Notion (US6): «Файл → Импорт из Notion…» → окно выбора (путь через ⌘⇧G) → «Импортировать» → лист отчёта
/// → страницы выгрузки в базе. Повтор той же выгрузки — вопрос до начала, «Отмена» дублей не создаёт.
final class NotionImportUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testImportFromFileMenuShowsReportAndWarnsOnRepeat() throws {
        let library = try UITestLibrary.make(for: self)
        let bundled = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "synthetic-nested", withExtension: "zip"),
                                    "Образца выгрузки нет в ресурсах UI-тестов")
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("NotionExport-\(UUID().uuidString).zip")
        try FileManager.default.copyItem(at: bundled, to: source)
        addTeardownBlock { try? FileManager.default.removeItem(at: source) }

        let app = library.launchApp()
        XCTAssertTrue(app.pageTitle.waitForExistence(timeout: 10))

        chooseExport(source, in: app)
        let report = app.descendants(matching: .any)["notion-import-report"]
        XCTAssertTrue(report.waitForExistence(timeout: 30), "Отчёт об импорте не появился")
        let summary = app.staticTexts["notion-import-summary"]
        XCTAssertTrue(summary.label.contains("Перенесено страниц: 6"), "Отчёт: \(summary.label)")
        XCTAssertTrue(summary.label.contains("Импорт из Notion — "), "Нет названия ветки: \(summary.label)")
        XCTAssertTrue(app.descendants(matching: .any)["notion-import-simplified"].exists, "Нет списка упрощённого")
        app.buttons["notion-import-done"].click()
        XCTAssertTrue(waitForAbsence(report), "Отчёт не закрылся")

        // Та же выгрузка ещё раз: вопрос до начала, «Отмена» — ничего не импортируется.
        chooseExport(source, in: app)
        let repeatWarning = app.descendants(matching: .any)["notion-import-repeat"]
        XCTAssertTrue(repeatWarning.waitForExistence(timeout: 30), "Нет вопроса о повторном импорте")
        app.buttons["notion-import-cancel-repeat"].click()
        XCTAssertTrue(waitForAbsence(repeatWarning), "Вопрос о повторе не закрылся")
        app.quit()

        let projects = try library.savedBlocks(ofPage: "Проекты")
        XCTAssertEqual(projects.first?.kind, "paragraph")
        XCTAssertTrue(projects.contains { $0.kind == "checkbox" && $0.isChecked && $0.text == "Сделано" }, "\(projects)")
        XCTAssertEqual(projects.filter { $0.kind == "pageLink" }.count, 3, "Ссылки на MyNotion, Задачи и Дневник: \(projects)")
        XCTAssertEqual(try library.savedBlocks(ofPage: "Купить молоко").map(\.text), ["Статус: Готово\nСрок: 18 октября 2026", "Две бутылки."])
        XCTAssertEqual(try library.savedIcon(ofPage: "Проекты"), "📁")
    }

    /// Меню «Файл → Импорт из Notion…», путь к выгрузке через «Перейти к папке» (⌘⇧G), «Импортировать».
    @MainActor
    private func chooseExport(_ source: URL, in app: XCUIApplication) {
        app.menuBars.menuBarItems["Файл"].click()
        app.menuItems["Импорт из Notion…"].click()
        let importButton = app.buttons["Импортировать"].firstMatch
        XCTAssertTrue(importButton.waitForExistence(timeout: 10), "Окно выбора выгрузки не открылось")
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeText(source.resolvingSymlinksInPath().path)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(importButton.waitForExistence(timeout: 5))
        // «Импортировать» — кнопка по умолчанию; щелчок по ней находит ещё и копию в Touch Bar.
        app.typeKey(.return, modifierFlags: [])
    }

    private func waitForAbsence(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }
}
