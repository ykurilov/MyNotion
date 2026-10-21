import AppKit
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
        // «Альфа» длинная: место прокрутки видно по тому, что текст уехал вверх за край окна.
        app.createPage(titled: "Альфа")
        // Вставка, а не набор: 60 строк набором — минуты.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString((1...60).map { "строка \($0) длинной страницы" }.joined(separator: "\n"), forType: .string)
        app.typeKey("v", modifierFlags: .command)
        XCTAssertTrue(waitUntil { (app.pageBody.value as? String ?? "").contains("строка 60") }, "Текст не вставился")
        for title in ["Бета", "Гамма", "Дельта"] { app.createPage(titled: title) }

        // Три перехода из панели: Альфа (прокрутить до конца) → Бета → Гамма.
        open(app, "Альфа")
        // Фокус после щелчка в панели остаётся в дереве: курсор — в текст, затем в конец страницы.
        app.pageBody.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 200, dy: 400)).click()
        app.typeKey(.downArrow, modifierFlags: .command)
        XCTAssertTrue(waitUntil { self.isScrolledDown(app) }, "«Альфа» не прокрутилась вниз: текст \(app.pageBody.frame)")
        open(app, "Бета")
        open(app, "Гамма")

        // ⌘[ дважды — «Альфа» на прежнем месте (название за краем); ⌘] — «Бета».
        app.typeKey("[", modifierFlags: .command)
        XCTAssertTrue(waitForBreadcrumb(app, "Бета"))
        app.typeKey("[", modifierFlags: .command)
        XCTAssertTrue(waitForBreadcrumb(app, "Альфа"))
        XCTAssertTrue(waitUntil { self.isScrolledDown(app) }, "«Назад» не вернул место прокрутки «Альфы»: текст \(app.pageBody.frame)")
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
        let rows = app.descendants(matching: .any).matching(identifier: "recent-page-row")
        XCTAssertTrue(waitUntil { rows.firstMatch.exists && rows.firstMatch.label == "Дельта" },
                      "Выдача: \(rows.allElementsBoundByIndex.map(\.label)), поле: \(field.value as? String ?? "—")")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitForTabs(app, ["Гамма", "Дельта"], active: "Дельта"))

        // ⌘-щелчок в панели: новая вкладка справа от текущей, активная — прежняя.
        XCUIElement.perform(withKeyModifiers: .command) { self.middle(app, "Альфа").click() }
        XCTAssertTrue(waitForBreadcrumb(app, "Дельта"), "⌘-щелчок сменил страницу активной вкладки")
        XCTAssertTrue(waitForTabs(app, ["Гамма", "Дельта", "Альфа"], active: "Дельта"))

        // ⌃⇥ и ⌃⇧⇥ — по кругу; у каждой вкладки своя история.
        app.typeKey(.tab, modifierFlags: .control)
        XCTAssertTrue(waitForBreadcrumb(app, "Альфа"))
        XCTAssertFalse(app.buttons["tab-back"].isEnabled, "у новой вкладки истории нет")
        app.typeKey(.tab, modifierFlags: .control)
        XCTAssertTrue(waitForBreadcrumb(app, "Гамма"))
        app.typeKey(.tab, modifierFlags: [.control, .shift])
        XCTAssertTrue(waitForBreadcrumb(app, "Альфа"))

        // Щелчок по вкладке.
        tab(app, "Дельта").click()
        XCTAssertTrue(waitForBreadcrumb(app, "Дельта"), "щелчок по вкладке не переключил её")
        tab(app, "Альфа").click()
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

        // «Показать все» и сразу ⌘Q: вкладка «Недавние» без редактора тоже записывается при выходе.
        app.buttons["recents-show-all"].click()
        app.quit()
        app = library.launchApp()
        XCTAssertTrue(waitForTabs(app, ["Дельта", "Недавние", "Гамма"], active: "Недавние", timeout: 10))
        app.terminate()
    }

    // MARK: Помощники

    /// Текст страницы уехал вверх за край окна.
    @MainActor
    private func isScrolledDown(_ app: XCUIApplication) -> Bool {
        app.pageBody.frame.minY < app.windows.firstMatch.frame.minY - 200
    }

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
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'window-tab'"))
    }

    @MainActor
    private func tab(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        tabs(app).matching(NSPredicate(format: "label == %@", title)).firstMatch
    }

    @MainActor
    private func waitForTabs(_ app: XCUIApplication, _ titles: [String], active: String, timeout: TimeInterval = 5,
                             file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let ok = waitUntil(timeout: timeout) {
            let all = self.tabs(app).allElementsBoundByIndex
            return all.map(\.label) == titles && all.first { $0.identifier == "window-tab-active" }?.label == active
        }
        if !ok {
            let all = tabs(app).allElementsBoundByIndex
            XCTFail("Вкладки: \(all.map(\.label)), активная: \(all.first { $0.identifier == "window-tab-active" }?.label ?? "нет")",
                    file: file, line: line)
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
