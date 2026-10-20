import XCTest

/// US7 «Шаблоны» вживую (003): «Сделать шаблоном» → раздел «Шаблоны»; ⌘N → строка шаблона → копия с подстраницами,
/// курсор в названии, «@сегодня» — день создания; «Новая страница по шаблону» из меню строки; «Перестать быть шаблоном».
/// Правила копии и дат на уровне данных — `TemplateOperationsTests`, `TemplateInstantiationTests`, `TemplateRowsTests`.
final class TemplatesTests: XCTestCase {
    private var library: UITestLibrary!
    private static let meeting = "Шаблон: заметки встречи"

    override func setUpWithError() throws {
        continueAfterFailure = false
        library = try UITestLibrary.make(for: self)
    }

    @MainActor
    func testMakeTemplateFillAndStop() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--database", library.databaseURL.path, "--generate-003-sample",
                               "-NSWindow Frame pages-AppWindow-1", UITestLibrary.startWindowFrame]
        app.launch()
        XCTAssertTrue(app.outlines["page-tree"].waitForExistence(timeout: 20))
        XCTAssertTrue(waitForTemplates(app, ["Шаблон: заметки встречи", "Шаблон: план на неделю", "Шаблон: дневник"]),
                      "В разделе «Шаблоны» не три шаблона образца")

        // «•••» → «Сделать шаблоном» у страницы с подстраницами: она уходит из «Страниц» в «Шаблоны».
        open(app, "Копии: исходная")
        let menu = app.descendants(matching: .any)["page-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.click()
        let make = app.descendants(matching: .any)["page-menu-template"]
        XCTAssertTrue(make.waitForExistence(timeout: 5), "В меню «•••» нет «Сделать шаблоном»")
        make.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(waitForTemplates(app, ["Шаблон: заметки встречи", "Шаблон: план на неделю", "Шаблон: дневник", "Копии: исходная"]))
        XCTAssertTrue(treeRow(app, "Копии: исходная").waitForNonExistence(timeout: 5), "Шаблон остался в «Страницах»")

        // ⌘N → пустая страница → строка шаблона «заметки встречи»: копия с подстраницами, курсор в названии.
        app.typeKey("n", modifierFlags: .command)
        let firstRow = app.descendants(matching: .any)["template-row-0"]
        XCTAssertTrue(firstRow.waitForExistence(timeout: 10), "На пустой странице нет строк шаблонов")
        firstRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        waitForTitle(app, Self.meeting)
        XCTAssertTrue(waitForBody(app) { $0.contains("Повестка") && $0.contains("Итоги") && $0.contains("Задачи после встречи") },
                      "В копии нет подстраниц: \(app.pageBody.value ?? "")")
        XCTAssertTrue(app.textFields["page-title"].value(forKey: "hasKeyboardFocus") as? Bool ?? false, "Курсор не в названии копии")
        XCTAssertFalse(app.descendants(matching: .any)["template-row-0"].exists, "Строки шаблонов остались на заполненной странице")

        // Меню строки шаблона → «Новая страница по шаблону».
        templateRow(app, "Шаблон: дневник").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
        XCTAssertTrue(app.menuItems["Новая страница по шаблону"].waitForExistence(timeout: 5), "В меню шаблона нет «Новая страница по шаблону»")
        app.menuItems["Новая страница по шаблону"].click()
        waitForTitle(app, "Шаблон: дневник")
        XCTAssertTrue(waitForBody(app) { $0.contains("Как прошёл день:") }, "В новой странице нет текста шаблона: \(app.pageBody.value ?? "")")

        // «Перестать быть шаблоном»: страница снова в «Страницах».
        templateRow(app, "Копии: исходная").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
        XCTAssertTrue(app.menuItems["Перестать быть шаблоном"].waitForExistence(timeout: 5))
        app.menuItems["Перестать быть шаблоном"].click()
        XCTAssertTrue(waitForTemplates(app, ["Шаблон: заметки встречи", "Шаблон: план на неделю", "Шаблон: дневник"]))
        XCTAssertTrue(treeRow(app, "Копии: исходная").waitForExistence(timeout: 5), "Страница не вернулась в «Страницы»")

        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))

        // «@сегодня» копии — день создания; у самого шаблона отметка осталась.
        let today = Date().formatted(.iso8601.year().month().day())
        let styles = try library.savedTextStyles(ofPage: Self.meeting)
        let copies = styles.filter { !$0.contains("templateRelative") && $0.contains("\"date\"") }
        XCTAssertEqual(copies.count, 1, "Дата копии: \(styles)")
        XCTAssertTrue(copies[0].contains(today), "В копии не сегодняшняя дата: \(copies[0])")
        XCTAssertEqual(styles.filter { $0.contains("templateRelative") }.count, 1, "Отметка «@сегодня» у шаблона пропала: \(styles)")
    }

    // MARK: Помощники

    @MainActor
    private func open(_ app: XCUIApplication, _ title: String) {
        let row = treeRow(app, title)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "В дереве нет «\(title)»")
        // Первый щелчок после запуска может уйти, пока окно открывает первую страницу: повтор, пока не открылась.
        for _ in 0..<3 where app.textFields["page-title"].value as? String != title {
            row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline, app.textFields["page-title"].value as? String != title {
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
        }
        waitForTitle(app, title)
    }

    @MainActor
    private func waitForTitle(_ app: XCUIApplication, _ title: String) {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if app.textFields["page-title"].value as? String == title { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("Открыта «\(app.textFields["page-title"].value as? String ?? "nil")», ждали «\(title)»")
    }

    @MainActor
    private func waitForBody(_ app: XCUIApplication, _ matches: (String) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if matches(app.pageBody.value as? String ?? "") { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    @MainActor
    private func templateTitles(_ app: XCUIApplication) -> [String] {
        app.outlines["templates-tree"].descendants(matching: .any).matching(identifier: "templates-row-title")
            .allElementsBoundByIndex.compactMap { $0.value as? String }
    }

    @MainActor
    private func waitForTemplates(_ app: XCUIApplication, _ expected: [String]) -> Bool {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if templateTitles(app) == expected { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("Раздел «Шаблоны»: \(templateTitles(app)), ждали \(expected)")
        return false
    }

    @MainActor
    private func treeRow(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.outlines["page-tree"].outlineRows.containing(NSPredicate(format: "value == %@", title)).firstMatch
    }

    @MainActor
    private func templateRow(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.outlines["templates-tree"].outlineRows.containing(NSPredicate(format: "value == %@", title)).firstMatch
    }
}
