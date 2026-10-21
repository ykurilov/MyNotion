import XCTest

/// US5 «Формулы» вживую (spec, US5): редактор формулы у «Задач» — формулы из spec дают итог для первой строки и тип,
/// ошибка подсвечена по-русски и «Готово» неактивно, круг не сохраняется, список ищет по набранному, «Готово» сохраняет.
/// Язык, пересчёт, фильтр и сортировка по формуле — `FormulasTests`, `FormulaRecomputeTests`.
final class FormulaEditorTests: XCTestCase {
    private var library: UITestLibrary!

    override func setUpWithError() throws {
        continueAfterFailure = false
        library = try UITestLibrary.make(for: self)
    }

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--database", library.databaseURL.path, "--formula-editor-demo",
                               "-NSWindow Frame pages-AppWindow-1", UITestLibrary.startWindowFrame]
        app.launch()
        return app
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    @MainActor
    private func replace(_ field: XCUIElement, with text: String) {
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeKey(.delete, modifierFlags: [])
        field.typeText(text)
    }

    @MainActor
    private func waitFor(_ element: XCUIElement, value predicate: @escaping (String) -> Bool, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate(element.value as? String ?? element.label) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return predicate(element.value as? String ?? element.label)
    }

    @MainActor
    func testFormulasFromSpecErrorsAndSave() throws {
        let app = launch()
        let field = element(app, "formula-field")
        XCTAssertTrue(field.waitForExistence(timeout: 30), "Редактор формулы не открылся")
        let output = element(app, "formula-output"), type = element(app, "formula-type"), done = element(app, "formula-done")
        XCTAssertTrue(waitFor(output) { $0 == "Нет итога" })

        // Формулы spec, US5: итог для первой строки и тип.
        replace(field, with: #"dateBetween(prop("Срок"), now(), "days")"#)
        XCTAssertTrue(waitFor(type) { $0 == "Тип: число" }, "тип: \(type.value ?? "")")
        XCTAssertTrue(waitFor(output) { Int($0) != nil }, "итог dateBetween не число: \(output.value ?? "")")
        replace(field, with: #"if(prop("Сделано"), "✅", "⏳")"#)
        XCTAssertTrue(waitFor(output) { $0 == "✅" || $0 == "⏳" }, "итог if: \(output.value ?? "")")
        XCTAssertTrue(waitFor(type) { $0 == "Тип: текст" })
        replace(field, with: #"prop("Часы") * 1.2"#)
        XCTAssertTrue(waitFor(type) { $0 == "Тип: число" })
        replace(field, with: #"prop("Проект").map(current.prop("Название")).join(", ")"#)
        XCTAssertTrue(waitFor(output) { $0.hasPrefix("Проект") }, "итог по связи: \(output.value ?? "")")
        XCTAssertTrue(done.isEnabled)

        // Ошибка: по-русски, «Готово» неактивно.
        replace(field, with: "if(true, 1")
        XCTAssertTrue(waitFor(output) { $0 == "Ожидалась „)“" }, "ошибка: \(output.value ?? "")")
        XCTAssertFalse(done.isEnabled, "«Готово» активно при ошибке")
        replace(field, with: #"dateBetween("2026", now(), "days")"#)
        XCTAssertTrue(waitFor(output) { $0 == "Функция dateBetween ждёт дату, а получила текст" })
        XCTAssertFalse(done.isEnabled)
        replace(field, with: #"prop("Формула") + 1"#)
        XCTAssertTrue(waitFor(output) { $0 == "Формула ссылается сама на себя: Формула → Формула" })
        XCTAssertFalse(done.isEnabled)
        replace(field, with: #"style("a", "red")"#)
        XCTAssertTrue(waitFor(output) { $0 == "Функция style не поддерживается в MyNotion" })

        // Список ищет по набранному слову; описание — синтаксис выбранного.
        replace(field, with: "dateBet")
        XCTAssertTrue(waitFor(element(app, "formula-description-title")) { $0.hasPrefix("dateBetween(") })

        // «Готово» сохраняет и закрывает.
        replace(field, with: #"prop("Часы") * 2"#)
        XCTAssertTrue(waitFor(type) { $0 == "Тип: число" })
        done.click()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), "Редактор не закрылся после «Готово»")
    }
}
