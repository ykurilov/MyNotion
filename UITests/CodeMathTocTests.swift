import XCTest

/// Код, формулы, оглавление вживую (US4, Independent Test): «```» даёт блок кода с курсором в нём, набор и ⌘Z в коде,
/// ⌘Enter — выход под блок; ⌃⇧E — формула в строке; «/оглавление» — оглавление с заголовком страницы; «$$ » — формула-блок
/// с окном правки. Логика каждого шага — в модульных тестах PageEditorTests; здесь — что части работают вместе.
final class CodeMathTocTests: XCTestCase {
    private var library: UITestLibrary!

    override func setUpWithError() throws {
        continueAfterFailure = false
        library = try UITestLibrary.make(for: self)
    }

    @MainActor
    func testCodeFormulasAndTableOfContents() throws {
        let app = library.launchApp()
        app.createPage(titled: "Код и формулы")
        app.typeText("## Раздел")
        app.typeKey(.return, modifierFlags: [])

        // Формула в строке из выделенного текста.
        app.typeText("Итог x^2")
        for _ in 0..<3 { app.typeKey(.leftArrow, modifierFlags: .shift) }
        app.typeKey("e", modifierFlags: [.control, .shift])
        app.typeKey(.rightArrow, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])

        // Блок кода: курсор сразу в нём, Enter — строка внутри, ⌘Z и ⇧⌘Z — общая отмена окна.
        app.typeText("```")
        let code = app.textViews["code-editor"]
        XCTAssertTrue(code.waitForExistence(timeout: 5), "Нет редактора кода на странице")
        app.typeText("let x = 1")
        app.typeKey(.return, modifierFlags: [])
        app.typeText("y")
        XCTAssertTrue(waitUntil { (code.value as? String) == "let x = 1\ny" }, "Набор не попал в код: \(code.value ?? "")")
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(waitUntil { (code.value as? String) == "" }, "⌘Z не отменил набор в коде: \(code.value ?? "")")
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitUntil { (code.value as? String) == "let x = 1\ny" }, "⇧⌘Z не вернул код")
        app.typeKey(.return, modifierFlags: .command)

        // Оглавление показывает заголовок страницы.
        app.typeText("/оглавление")
        XCTAssertTrue(app.popupItem("tableOfContents").waitForExistence(timeout: 5), "Меню «/» не нашло оглавление")
        app.typeKey(.return, modifierFlags: [])
        let toc = app.descendants(matching: .any)["table-of-contents"]
        XCTAssertTrue(toc.waitForExistence(timeout: 5), "Нет оглавления на странице")
        XCTAssertTrue(waitUntil { (toc.value as? String) == "Раздел" }, "Оглавление без заголовка: \(toc.value ?? "")")

        // Формула-блок: окно правки, Enter — готово.
        app.typeText("$$ ")
        let field = app.textViews["equation-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Окно правки формулы не открылось")
        app.typeText("E=mc^2")
        app.typeKey(.return, modifierFlags: [])
        let equation = app.descendants(matching: .any)["equation-block"]
        XCTAssertTrue(waitUntil { (equation.value as? String) == "E=mc^2" }, "Формула не записалась: \(equation.value ?? "")")

        app.quit()
        let saved = try library.savedBlocks(ofPage: "Код и формулы")
        XCTAssertEqual(saved, [
            .init(kind: "heading2", text: "Раздел"),
            .init(kind: "paragraph", text: "Итог \u{FFFC}"),
            .init(kind: "code", text: "let x = 1\ny"),
            .init(kind: "tableOfContents", text: ""),
            .init(kind: "equation", text: "E=mc^2"),
        ])
        XCTAssertTrue(try library.savedTextStyles(ofPage: "Код и формулы")[1].contains("\"equation\""), "Нет формулы в строке")
    }

    /// Ждать условия до 5 с, не держа паузу дольше нужного.
    @MainActor
    private func waitUntil(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }
}
