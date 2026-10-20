import XCTest

/// «/» → «Страница» вживую, как в Notion 7.39: подстраница на месте пустого абзаца, сразу открыта с курсором в названии;
/// назад — ссылка на месте с названием; ⌘Z на исходной странице — один шаг, ⇧⌘Z возвращает.
/// Место в дереве, отмена и «Преобразовать в» — в модульных тестах `InlineSubpageTests` и `SlashPageTests`.
final class SlashPageTests: XCTestCase {
    private var library: UITestLibrary!

    override func setUpWithError() throws {
        continueAfterFailure = false
        library = try UITestLibrary.make(for: self)
    }

    @MainActor
    func testSlashPageCreatesSubpageInPlaceAndUndoesInOneStep() throws {
        let app = library.launchApp()
        app.createPage(titled: "Проекты")
        app.typeText("до")
        app.typeKey(.return, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        app.typeText("после")
        app.typeKey(.upArrow, modifierFlags: [])

        app.typeText("/стр")
        XCTAssertTrue(app.popupItem("pageLink").waitForExistence(timeout: 5), "В меню «/» нет «Страница»")
        app.typeKey(.return, modifierFlags: [])

        // Открыта новая подстраница, курсор в названии.
        let breadcrumb = app.staticTexts["page-breadcrumb"]
        XCTAssertTrue(waitUntil { (breadcrumb.value as? String ?? breadcrumb.label).hasPrefix("Проекты") &&
            (breadcrumb.value as? String ?? breadcrumb.label) != "Проекты" }, "Подстраница не открылась: \(breadcrumb.label)")
        app.typeText("План")
        XCTAssertTrue(row(app, "План").waitForExistence(timeout: 5), "В дереве нет «План»")

        // Ссылка встала на место пустого абзаца (подстраница с ссылкой пишется в базу сразу, одной транзакцией).
        let withLink = ["paragraph до", "pageLink ", "paragraph после"]
        XCTAssertTrue(waitUntil { (try? self.blocks("Проекты")) == withLink }, "В базе: \(String(describing: try? blocks("Проекты")))")

        // Назад и ⌘Z — один шаг: ссылки и подстраницы нет, пустой абзац на месте; ⇧⌘Z — всё вернулось.
        row(app, "Проекты").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(waitUntil { (breadcrumb.value as? String ?? breadcrumb.label) == "Проекты" }, "Не вернулись на «Проекты»")
        app.pageBody.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).click()
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(waitUntil { (try? self.blocks("Проекты")) == ["paragraph до", "paragraph ", "paragraph после"] },
                      "После ⌘Z: \(String(describing: try? blocks("Проекты")))")
        XCTAssertTrue(waitUntil { !self.row(app, "План").exists }, "⌘Z не убрал подстраницу из дерева")
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitUntil { (try? self.blocks("Проекты")) == withLink }, "После ⇧⌘Z: \(String(describing: try? blocks("Проекты")))")
        XCTAssertTrue(row(app, "План").waitForExistence(timeout: 5))

        app.quit()
        XCTAssertEqual(try blocks("Проекты"), withLink)
    }

    /// «Преобразовать в → Страница» у переключателя с вложенным: ссылка на месте, дети — внутри подстраницы; ⌘Z — один шаг.
    @MainActor
    func testTurnIntoPageMovesChildrenAndUndoesInOneStep() throws {
        let app = library.launchApp()
        app.createPage(titled: "Проекты")
        app.typeText("> Раздел")
        app.typeKey(.return, modifierFlags: [])
        app.typeText("пункт")
        XCTAssertTrue(waitUntil { (try? self.blocks("Проекты").map { $0.split(separator: " ").dropFirst().joined(separator: " ") })
            == ["Раздел", "пункт"] }, "В базе: \(String(describing: try? blocks("Проекты")))")
        let before = try blocks("Проекты")

        XCTAssertTrue(app.hoverFirstBlock(), "Ручки «⋮⋮» у первого блока не появились")
        app.blockDragHandle.click()
        XCTAssertTrue(app.popupItem("turn-into").waitForExistence(timeout: 5), "Меню блока не открылось")
        // Строки меню — свои виды, не системное меню: щелчок и наведение — по точке (как в ColorTests).
        app.popupItem("turn-into").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
        XCTAssertTrue(app.popupItem("pageLink").waitForExistence(timeout: 5), "В «Преобразовать в» нет «Страница»")
        app.popupItem("pageLink").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()

        XCTAssertTrue(waitUntil { (try? self.blocks("Проекты")) == ["pageLink "] }, "В базе: \(String(describing: try? blocks("Проекты")))")
        XCTAssertTrue(waitUntil { (try? self.blocks("Раздел").map { $0.split(separator: " ").dropFirst().joined(separator: " ") })
            == ["пункт"] }, "В подстранице: \(String(describing: try? blocks("Раздел")))")
        XCTAssertTrue(row(app, "Раздел").waitForExistence(timeout: 5), "В дереве нет «Раздел»")

        app.pageBody.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).click()
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(waitUntil { (try? self.blocks("Проекты")) == before }, "После ⌘Z: \(String(describing: try? blocks("Проекты")))")
        XCTAssertTrue(waitUntil { !self.row(app, "Раздел").exists }, "⌘Z не убрал подстраницу из дерева")
        app.quit()
    }

    /// Блоки страницы из базы: «тип текст».
    private func blocks(_ title: String) throws -> [String] {
        try library.savedBlocks(ofPage: title).map { "\($0.kind) \($0.text)" }
    }

    @MainActor
    private func row(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.outlines["page-tree"].outlineRows.containing(NSPredicate(format: "value == %@", title)).firstMatch
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
