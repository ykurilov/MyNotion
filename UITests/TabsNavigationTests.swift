import XCTest

/// US3 «Вкладки и назад/вперёд» (T048, spec, Independent Test): переходы и ⌘[ / ⌘] с возвратом места прокрутки,
/// серые «‹ ›» на краях, ⌘T → «Открыть в новой вкладке» → страница, ⌘-щелчок в панели, ⌃⇥ / ⌃⇧⇥, перетаскивание,
/// ⌘W и ⇧⌘T, перезапуск — вкладки и активная на месте.
final class TabsNavigationTests: XCTestCase {
    private var library: UITestLibrary!

    override func setUpWithError() throws {
        continueAfterFailure = false
        library = try UITestLibrary.make(for: self)
    }

    @MainActor
    func testTabsHistoryAndRelaunch() throws {
        var app = library.launchApp()
        // «Альфа» длинная: место прокрутки видно по тому, что название ушло вверх за край.
        app.createPage(titled: "Альфа")
        app.typeText(Array(repeating: "строка длинной страницы", count: 60).joined(separator: "\n"))
        for title in ["Бета", "Гамма", "Дельта"] { app.createPage(titled: title) }

        // Три перехода из панели: Альфа (прокрутить до конца) → Бета → Гамма.
        open(app, "Альфа")
        app.pageBody.typeKey(.downArrow, modifierFlags: .command)
        XCTAssertTrue(waitUntil { !app.pageTitle.isHittable }, "«Альфа» не прокрутилась вниз")
        open(app, "Бета")
        open(app, "Гамма")

        // ⌘[ дважды — «Альфа» на прежнем месте (название за краем); ⌘] — «Бета».
        app.typeKey("[", modifierFlags: .command)
        XCTAssertTrue(waitForBreadcrumb(app, "Бета"))
        app.typeKey("[", modifierFlags: .command)
        XCTAssertTrue(waitForBreadcrumb(app, "Альфа"))
        XCTAssertTrue(waitUntil { !app.pageTitle.isHittable }, "«Назад» не вернул место прокрутки «Альфы»")
        app.typeKey("]", modifierFlags: .command)
        XCTAssertTrue(waitForBreadcrumb(app, "Бета"))

        // «›» до конца истории — серая; «‹» — нет.
        app.buttons["tab-forward"].click()
        XCTAssertTrue(waitForBreadcrumb(app, "Гамма"))
        XCTAssertTrue(waitUntil { !app.buttons["tab-forward"].isEnabled }, "«›» не посерела в конце истории")
        XCTAssertTrue(app.buttons["tab-back"].isEnabled)

        // ⌘T — окно «Открыть в новой вкладке»: поиск «Дельта», Enter — новая вкладка в конце, активная.
        app.typeKey("t", modifierFlags: .command)
        let field = app.textFields["new-tab-search-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "⌘T не открыл окно поиска")
        app.typeText("Дельта")
        XCTAssertTrue(waitUntil { app.descendants(matching: .any).matching(identifier: "recent-page-row").count == 1 })
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitForTabs(app, ["Гамма", "Дельта"], active: "Дельта"))

        // ⌘-щелчок в панели: новая вкладка справа от текущей, активная — прежняя.
        XCUIElement.perform(withKeyModifiers: .command) { self.middle(app, "Альфа").click() }
        XCTAssertTrue(waitForTabs(app, ["Гамма", "Дельта", "Альфа"], active: "Дельта"))
        XCTAssertTrue(waitForBreadcrumb(app, "Дельта"))

        // ⌃⇥ и ⌃⇧⇥ — по кругу; у каждой вкладки своя история.
        app.typeKey(.tab, modifierFlags: .control)
        XCTAssertTrue(waitForBreadcrumb(app, "Альфа"))
        XCTAssertFalse(app.buttons["tab-back"].isEnabled, "у новой вкладки истории нет")
        app.typeKey(.tab, modifierFlags: .control)
        XCTAssertTrue(waitForBreadcrumb(app, "Гамма"))
        app.typeKey(.tab, modifierFlags: [.control, .shift])
        XCTAssertTrue(waitForBreadcrumb(app, "Альфа"))

        // Перетаскивание: «Гамма» — в конец.
        tab(app, "Гамма").press(forDuration: 0.3, thenDragTo: tab(app, "Альфа"))
        XCTAssertTrue(waitForTabs(app, ["Дельта", "Альфа", "Гамма"], active: "Альфа"))

        // ⌘W закрывает активную, ⇧⌘T возвращает её на место.
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(waitForTabs(app, ["Дельта", "Гамма"], active: "Гамма"))
        app.typeKey("t", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitForTabs(app, ["Дельта", "Альфа", "Гамма"], active: "Альфа"))

        // Перезапуск: вкладки, порядок и активная на месте.
        app.quit()
        app = library.launchApp()
        XCTAssertTrue(waitForTabs(app, ["Дельта", "Альфа", "Гамма"], active: "Альфа", timeout: 10))
        XCTAssertTrue(waitForBreadcrumb(app, "Альфа"))
        app.terminate()
    }

    // MARK: Помощники

    @MainActor
    private func open(_ app: XCUIApplication, _ title: String) {
        middle(app, title).click()
        XCTAssertTrue(waitForBreadcrumb(app, title))
    }

    @MainActor
    private func middle(_ app: XCUIApplication, _ title: String) -> XCUICoordinate {
        app.outlines["page-tree"].outlineRows.containing(NSPredicate(format: "value == %@", title)).firstMatch
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    }

    @MainActor
    private func tabs(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: "window-tab")
    }

    @MainActor
    private func tab(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        tabs(app).matching(NSPredicate(format: "label == %@", title)).firstMatch
    }

    @MainActor
    private func waitForTabs(_ app: XCUIApplication, _ titles: [String], active: String, timeout: TimeInterval = 5) -> Bool {
        let ok = waitUntil(timeout: timeout) {
            let all = self.tabs(app).allElementsBoundByIndex
            return all.map(\.label) == titles && all.first { ($0.value as? String) == "активная" }?.label == active
        }
        if !ok {
            let all = tabs(app).allElementsBoundByIndex
            XCTFail("Вкладки: \(all.map(\.label)), активная: \(all.first { ($0.value as? String) == "активная" }?.label ?? "нет")")
        }
        return ok
    }

    @MainActor
    private func waitForBreadcrumb(_ app: XCUIApplication, _ title: String) -> Bool {
        let breadcrumb = app.staticTexts["page-breadcrumb"]
        return waitUntil { (breadcrumb.value as? String ?? breadcrumb.label) == title }
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
