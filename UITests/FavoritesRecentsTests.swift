import XCTest

/// US2 «Панель» вживую (003): избранное и недавние над деревом «Страницы».
/// Порядок, отмена и корзина на уровне данных — в модульных тестах `FavoriteOperationsTests` и `VisitRecorderTests`.
final class FavoritesRecentsTests: XCTestCase {
    private var databaseURL: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MyNotionUITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        databaseURL = folder.appendingPathComponent("MyNotion.sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
    }

    @MainActor
    func testFavoritesStarMenuDragTrashCollapseAndRelaunch() throws {
        var app = launchApp()
        for title in ["Альфа", "Бета", "Гамма"] { createPage(app, title: title) }

        // ☆ у открытой «Гаммы», потом у «Альфы».
        star(app).click()
        XCTAssertTrue(waitForTitles(app, in: "favorites", ["Гамма"]))
        rowMiddle(app, "Альфа").click()
        waitForStar(app, page: "Альфа", label: "Добавить в избранное")
        star(app).click()
        XCTAssertTrue(waitForTitles(app, in: "favorites", ["Гамма", "Альфа"]))

        // «Добавить в избранное» в меню строки панели — у «Беты».
        rowMiddle(app, "Бета").hover()
        let menuButton = treeRow(app, "Бета").descendants(matching: .any).matching(identifier: "page-tree-menu").firstMatch
        XCTAssertTrue(menuButton.waitForExistence(timeout: 5), "При наведении на строку нет кнопки «•••»")
        menuButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        app.menuItems["Добавить в избранное"].click()
        XCTAssertTrue(waitForTitles(app, in: "favorites", ["Гамма", "Альфа", "Бета"]))

        // Перетащить «Бету» в начало раздела.
        favoriteMiddle(app, "Бета").press(forDuration: 0.5, thenDragTo: favoriteMiddle(app, "Гамма"))
        XCTAssertTrue(waitForTitles(app, in: "favorites", ["Бета", "Гамма", "Альфа"]))

        // ☆ ещё раз у открытой «Альфы» — убрана.
        rowMiddle(app, "Альфа").click()
        waitForStar(app, page: "Альфа", label: "Убрать из избранного")
        star(app).click()
        XCTAssertTrue(waitForTitles(app, in: "favorites", ["Бета", "Гамма"]))

        // «Бета» в корзину — пропала из избранного; вернули — на своём месте.
        rowMiddle(app, "Бета").click()
        app.outlines["page-tree"].typeKey(.delete, modifierFlags: .command)
        XCTAssertTrue(waitForTitles(app, in: "favorites", ["Гамма"]))
        app.buttons["sidebar-trash"].click()
        let entry = app.descendants(matching: .any).matching(identifier: "trash-entry").firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.buttons["trash-restore"].click()
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitForTitles(app, in: "favorites", ["Бета", "Гамма"]))

        // Щелчок по заголовку сворачивает раздел, ещё щелчок — раскрывает.
        app.buttons["sidebar-section-favorites"].click()
        XCTAssertTrue(app.outlines["favorites-tree"].waitForNonExistence(timeout: 5))
        relaunch(&app)
        XCTAssertFalse(app.outlines["favorites-tree"].exists, "Свёрнутый раздел после перезапуска раскрылся")
        app.buttons["sidebar-section-favorites"].click()
        XCTAssertTrue(waitForTitles(app, in: "favorites", ["Бета", "Гамма"]))
        app.terminate()
    }

    @MainActor
    func testRecentsShowFiveLatestPages() throws {
        let app = launchApp()
        let titles = ["Раз", "Два", "Три", "Четыре", "Пять", "Шесть"]
        for title in titles { createPage(app, title: title) }

        // Каждую страницу держим открытой по 3 с: меньше двух секунд страница в недавние не попадает.
        for title in titles {
            rowMiddle(app, title).click()
            Thread.sleep(forTimeInterval: 3)
        }
        XCTAssertTrue(waitForTitles(app, in: "recents", ["Шесть", "Пять", "Четыре", "Три", "Два"]))
        XCTAssertTrue(app.buttons["recents-show-all"].exists, "Нет строки «Показать все»")
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

    @MainActor
    private func relaunch(_ app: inout XCUIApplication) {
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10), "Приложение не вышло по ⌘Q")
        app = launchApp()
    }

    @MainActor
    private func createPage(_ app: XCUIApplication, title: String) {
        app.typeKey("n", modifierFlags: [.command])
        XCTAssertTrue(app.textFields["page-title"].waitForExistence(timeout: 10))
        app.typeText(title)
        XCTAssertTrue(treeRow(app, title).waitForExistence(timeout: 5), "В дереве нет «\(title)»")
    }

    /// ☆ в верхней полосе открытой страницы.
    @MainActor
    private func star(_ app: XCUIApplication) -> XCUIElement {
        let star = app.buttons["page-favorite-star"]
        XCTAssertTrue(star.waitForExistence(timeout: 5), "В верхней полосе нет ☆")
        return star
    }

    /// Середина строки — куда кликает человек. Клик по самому элементу строки XCUITest наводит на край (как в PageTreeTests).
    /// Ждёт, пока открылась страница `page` и ☆ показывает нужное состояние: щелчок раньше времени попал бы по прошлой странице.
    @MainActor
    private func waitForStar(_ app: XCUIApplication, page: String, label: String) {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if app.textFields["page-title"].value as? String == page, app.buttons["page-favorite-star"].label == label { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("Ждали страницу «\(page)» с ☆ «\(label)», есть «\(app.textFields["page-title"].value as? String ?? "nil")» и «\(app.buttons["page-favorite-star"].label)»")
    }

    @MainActor
    private func rowMiddle(_ app: XCUIApplication, _ title: String) -> XCUICoordinate {
        treeRow(app, title).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    }

    @MainActor
    private func treeRow(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.outlines["page-tree"].outlineRows.containing(NSPredicate(format: "value == %@", title)).firstMatch
    }

    @MainActor
    private func favoriteMiddle(_ app: XCUIApplication, _ title: String) -> XCUICoordinate {
        app.outlines["favorites-tree"].outlineRows.containing(NSPredicate(format: "value == %@", title)).firstMatch
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    }

    /// Названия строк раздела (`favorites` или `recents`) сверху вниз.
    @MainActor
    private func titles(_ app: XCUIApplication, in section: String) -> [String] {
        app.outlines["\(section)-tree"].descendants(matching: .any).matching(identifier: "\(section)-row-title")
            .allElementsBoundByIndex.compactMap { $0.value as? String }
    }

    @MainActor
    private func waitForTitles(_ app: XCUIApplication, in section: String, _ expected: [String]) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if titles(app, in: section) == expected { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("Раздел «\(section)»: \(titles(app, in: section)), ждали \(expected)")
        return false
    }
}
