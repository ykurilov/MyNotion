import XCTest

/// US2 вживую (сценарии 2.1–2.4): три уровня страниц, перенос ветки, свёрнутая ветка,
/// корзина и возврат, после перезапуска дерево и свёрнутые ветки те же.
/// Операции с деревом и отмена — в модульном тесте `PageTreeOperationsTests`.
final class PageTreeTests: XCTestCase {
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
    func testTreeSurvivesMoveTrashAndRelaunch() throws {
        var app = launchApp()

        // 2.1. Три уровня: «Проекты» → «MyNotion» → «Заметки»; рядом с «Проектами» — «Входящие».
        createPage(app, title: "Проекты", shortcut: [.command])
        createPage(app, title: "MyNotion", shortcut: [.command, .shift])
        createPage(app, title: "Заметки", shortcut: [.command, .shift])
        row(app, "Проекты").click()
        createPage(app, title: "Входящие", shortcut: [.command])
        XCTAssertEqual(visibleTitles(app), ["Проекты", "MyNotion", "Заметки", "Входящие"])

        // 2.2. Перетащить ветку «MyNotion» на «Входящие»: «Заметки» уезжают вместе с ней.
        row(app, "MyNotion").press(forDuration: 0.5, thenDragTo: row(app, "Входящие"))
        XCTAssertTrue(waitForTitles(app, ["Проекты", "Входящие", "MyNotion", "Заметки"]))

        // Свернуть «MyNotion»: выделить строку и нажать стрелку влево.
        row(app, "MyNotion").click()
        app.outlines["page-tree"].typeKey(.leftArrow, modifierFlags: [])
        XCTAssertTrue(waitForTitles(app, ["Проекты", "Входящие", "MyNotion"]))

        // 2.3. ⌘⌫ в дереве — «Проекты» в корзину.
        row(app, "Проекты").click()
        app.outlines["page-tree"].typeKey(.delete, modifierFlags: .command)
        XCTAssertTrue(waitForTitles(app, ["Входящие", "MyNotion"]))

        // 2.4. Вернуть из корзины — на своё место.
        app.buttons["sidebar-trash"].click()
        let entry = app.descendants(matching: .any).matching(identifier: "trash-entry").firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        XCTAssertEqual(entry.label, "Проекты")
        entry.buttons["trash-restore"].click()
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitForTitles(app, ["Проекты", "Входящие", "MyNotion"]))

        // Перезапуск: то же дерево, «MyNotion» по-прежнему свёрнута; развернуть — «Заметки» на месте.
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10), "Приложение не вышло по ⌘Q")
        app = launchApp()
        XCTAssertTrue(waitForTitles(app, ["Проекты", "Входящие", "MyNotion"]))
        row(app, "MyNotion").click()
        app.outlines["page-tree"].typeKey(.rightArrow, modifierFlags: [])
        XCTAssertTrue(waitForTitles(app, ["Проекты", "Входящие", "MyNotion", "Заметки"]))
        app.terminate()
    }

    // MARK: Помощники

    @MainActor
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--database", databaseURL.path]
        app.launch()
        XCTAssertTrue(app.outlines["page-tree"].waitForExistence(timeout: 10))
        return app
    }

    /// ⌘N — страница рядом, ⇧⌘N — подстраница открытой; курсор сразу в названии.
    @MainActor
    private func createPage(_ app: XCUIApplication, title: String, shortcut: XCUIElement.KeyModifierFlags) {
        app.typeKey("n", modifierFlags: shortcut)
        XCTAssertTrue(app.textFields["page-title"].waitForExistence(timeout: 10))
        app.typeText(title)
        XCTAssertTrue(row(app, title).waitForExistence(timeout: 5), "В дереве нет «\(title)»")
    }

    @MainActor
    private func row(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.outlines["page-tree"].outlineRows.containing(NSPredicate(format: "value == %@", title)).firstMatch
    }

    /// Названия видимых строк дерева сверху вниз.
    @MainActor
    private func visibleTitles(_ app: XCUIApplication) -> [String] {
        app.outlines["page-tree"].textFields.matching(identifier: "page-tree-title")
            .allElementsBoundByIndex.compactMap { $0.value as? String }
    }

    @MainActor
    private func waitForTitles(_ app: XCUIApplication, _ expected: [String]) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if visibleTitles(app) == expected { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("Дерево: \(visibleTitles(app)), ждали \(expected)")
        return false
    }
}
