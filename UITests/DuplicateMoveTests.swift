import XCTest

/// US4 «Копии» вживую (003): «Дублировать» из «•••» и ⌘D из панели, «Переместить в» для выделенных блоков (⇧⌘P)
/// и для страницы из меню строки панели; ⌘Z. Правила копии и переноса на уровне данных — `DuplicatePageTests`,
/// `MoveBlocksToPageTests`, `PagePickerModelTests`.
final class DuplicateMoveTests: XCTestCase {
    private var library: UITestLibrary!

    override func setUpWithError() throws {
        continueAfterFailure = false
        library = try UITestLibrary.make(for: self)
    }

    @MainActor
    func testDuplicateAndMoveTo() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--database", library.databaseURL.path, "--generate-003-sample",
                               "-NSWindow Frame pages-AppWindow-1", UITestLibrary.startWindowFrame]
        app.launch()
        XCTAssertTrue(app.outlines["page-tree"].waitForExistence(timeout: 20))

        // «•••» → «Дублировать»: открыта копия «(1)» сразу под оригиналом.
        open(app, "Копии: исходная")
        let menu = app.descendants(matching: .any)["page-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.click()
        let duplicate = app.descendants(matching: .any)["page-menu-duplicate"]
        XCTAssertTrue(duplicate.waitForExistence(timeout: 5), "В меню «•••» нет «Дублировать»")
        duplicate.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        waitForTitle(app, "Копии: исходная (1)")
        XCTAssertTrue((app.pageBody.value as? String ?? "").hasPrefix("Начало\nСписок\nпункт 1\nпункт 1.1\nКонец"),
                      "В копии другой текст: \(app.pageBody.value ?? "")")
        // Сразу под оригиналом: между его веткой и следующей страницей верхнего уровня.
        let original = treeRow(app, "Копии: исходная").frame.minY
        let copyRow = treeRow(app, "Копии: исходная (1)")
        XCTAssertTrue(copyRow.waitForExistence(timeout: 5), "Копии нет в дереве")
        let next = treeRow(app, "Копии: цель").frame.minY
        XCTAssertTrue(original < copyRow.frame.minY && copyRow.frame.minY < next, "Копия не сразу под оригиналом")

        // Три блока с вложенными («Список» › «пункт 1» › «пункт 1.1») → ⇧⌘P → поиск → Enter: в конце «цели».
        open(app, "Копии: исходная")
        // Курсор — щелчком в первую строку «Начало»: после щелчка по панели клавиши идут в панель.
        app.pageBody.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 40, dy: 10)).click()
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey(.downArrow, modifierFlags: .shift)
        app.typeKey(.downArrow, modifierFlags: .shift)
        app.typeKey("p", modifierFlags: [.command, .shift])
        let field = app.descendants(matching: .any)["page-picker-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "⇧⌘P не открыл «Переместить в…»")
        app.typeText("Копии: цель")
        XCTAssertTrue(pickerRow(app, "Копии: цель").waitForExistence(timeout: 5), "Поиск не нашёл цель")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), "Окно выбора не закрылось")
        XCTAssertTrue(waitForBody(app) { $0.hasPrefix("Начало\nКонец") }, "Блоки остались: \(app.pageBody.value ?? "")")

        // ⌘Z — блоки снова на месте; ⇧⌘Z — снова у цели.
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(waitForBody(app) { $0.hasPrefix("Начало\nСписок\nпункт 1\nпункт 1.1\nКонец") }, "⌘Z не вернул блоки")
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitForBody(app) { $0.hasPrefix("Начало\nКонец") }, "⇧⌘Z не повторил перенос")
        open(app, "Копии: цель")
        XCTAssertTrue(waitForBody(app) { $0 == "Первый абзац цели\nСписок\nпункт 1\nпункт 1.1" }, "У цели: \(app.pageBody.value ?? "")")

        // ⌘D, когда фокус в панели: копия «цели».
        app.outlines["page-tree"].typeKey("d", modifierFlags: .command)
        waitForTitle(app, "Копии: цель (1)")

        // «Переместить в» из меню строки панели: «цель (1)» → внутрь «исходная (1)».
        // Меню строки — правой кнопкой (то же, что «•••» строки).
        treeRow(app, "Копии: цель (1)").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
        XCTAssertTrue(app.menuItems["Переместить в"].waitForExistence(timeout: 5), "В меню строки нет «Переместить в»")
        app.menuItems["Переместить в"].click()
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Меню строки не открыло «Переместить в…»")
        app.typeText("исходная (1)")
        XCTAssertTrue(pickerRow(app, "Копии: исходная (1)").waitForExistence(timeout: 5))
        pickerRow(app, "Копии: исходная (1)").click()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))

        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        let copy = try library.savedBlocks(ofPage: "Копии: исходная (1)").map(\.kind)
        XCTAssertEqual(copy.filter { $0 == "pageLink" }.count, 3, "Две подстраницы-копии и перенесённая «цель (1)»: \(copy)")
        XCTAssertTrue(copy.contains("image") && copy.contains("file"), "Картинка и файл не скопировались: \(copy)")
        XCTAssertEqual(try library.savedBlocks(ofPage: "Копии: цель").map(\.indent), [0, 0, 1, 2])
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
    private func treeRow(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.outlines["page-tree"].outlineRows.containing(NSPredicate(format: "value == %@", title)).firstMatch
    }

    @MainActor
    private func pickerRow(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'page-picker-row' AND label == %@", title)).firstMatch
    }
}
