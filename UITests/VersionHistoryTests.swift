import XCTest

/// История версий (US6, quickstart.md): правки с ускоренными часами записи (`--versions-quick`: версия через 1 с тишины,
/// не чаще раза в 2 с) → «•••» → «История версий»; группировка; раскрытие версии; ранняя версия с подсветкой →
/// «Восстановить» → «Восстановить эту версию» → полоса «Страница восстановлена»; ⌘Z — как было; Esc закрывает.
final class VersionHistoryTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testHistoryRestoreAndUndo() throws {
        let library = try UITestLibrary.make(for: self)
        let app = XCUIApplication()
        app.launchArguments = ["--database", library.databaseURL.path, "--versions-quick", "-MyNotion.recentColors", "",
                               "-NSWindow Frame pages-AppWindow-1", UITestLibrary.startWindowFrame]
        app.launch()
        app.createPage(titled: "История")

        // Три правки с паузами: у каждой своя версия.
        for (index, text) in ["первая правка", " вторая правка", " третья правка"].enumerated() {
            if index > 0 { pause(3.5) }
            app.typeText(text)
        }
        pause(2)
        XCTAssertTrue(bodyText(app).contains("третья правка"))

        openHistory(app)
        let rows = app.descendants(matching: .any).matching(identifier: "version-row")
        XCTAssertTrue(waitFor { rows.count >= 3 }, "Версий меньше трёх: \(rows.count)")
        let minuteCount = rows.count
        XCTAssertTrue(app.staticTexts["Текущая версия"].exists, "У самой новой нет метки «Текущая версия»")
        XCTAssertFalse(app.descendants(matching: .any)["version-begin-restore"].isEnabled, "«Восстановить» у текущей включена")

        // Группировка «1 час» — все правки в одном часе: одна строка; обратно «1 минута».
        chooseGrouping(app, "version-grouping-60")
        XCTAssertTrue(waitFor { rows.count == 1 }, "«1 час» не объединил версии: \(rows.count)")
        chooseGrouping(app, "version-grouping-1")
        XCTAssertTrue(waitFor { rows.count == minuteCount })

        // Самая ранняя версия: «Восстановить» включена; раскрытие — что менялось.
        rows.element(boundBy: minuteCount - 1).click()
        let restore = app.descendants(matching: .any)["version-begin-restore"]
        XCTAssertTrue(waitFor { restore.isEnabled }, "«Восстановить» не включилась у прошлой версии")
        rows.element(boundBy: minuteCount - 1).descendants(matching: .any)["version-expand"].firstMatch.click()
        XCTAssertTrue(app.descendants(matching: .any)["version-changes"].waitForExistence(timeout: 5), "Раскрытие не показало изменения")
        app.descendants(matching: .any)["version-all-versions"].click()
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))

        // «Восстановить» → окно «Что будет восстановлено» → «Восстановить эту версию».
        restore.click()
        let confirm = app.descendants(matching: .any)["version-restore-confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Окно «Что будет восстановлено» не открылось")
        XCTAssertTrue(app.staticTexts["Что будет восстановлено"].exists)
        confirm.click()
        XCTAssertTrue(app.descendants(matching: .any)["version-restored-banner"].waitForExistence(timeout: 5), "Нет полосы «Страница восстановлена»")
        XCTAssertFalse(app.descendants(matching: .any)["version-history"].exists, "История не закрылась после восстановления")
        XCTAssertTrue(waitFor { !bodyText(app).contains("вторая правка") }, "Страница не стала как в ранней версии: \(bodyText(app))")
        add(XCTAttachment(screenshot: app.screenshot()))

        // ⌘Z — страница как до восстановления.
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(waitFor { bodyText(app).contains("третья правка") }, "⌘Z не вернул страницу: \(bodyText(app))")

        // История снова открывается; прошлые версии на месте; Esc закрывает.
        openHistory(app)
        XCTAssertTrue(waitFor { rows.count >= minuteCount + 1 }, "Версии пропали после восстановления: \(rows.count)")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitFor { !app.descendants(matching: .any)["version-history"].exists }, "Esc не закрыл историю")
    }

    @MainActor
    private func openHistory(_ app: XCUIApplication) {
        let menu = app.descendants(matching: .any)["page-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.click()
        let item = app.descendants(matching: .any)["page-menu-versionHistory"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "В меню нет «История версий»")
        item.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(app.descendants(matching: .any)["version-history"].waitForExistence(timeout: 5), "История не открылась")
    }

    @MainActor
    private func chooseGrouping(_ app: XCUIApplication, _ identifier: String) {
        app.descendants(matching: .any)["version-grouping"].firstMatch.click()
        let item = app.menuItems.matching(identifier: identifier).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "Нет пункта группировки \(identifier)")
        item.click()
    }

    @MainActor
    private func bodyText(_ app: XCUIApplication) -> String {
        app.pageBody.value as? String ?? ""
    }

    private func pause(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    @MainActor
    private func waitFor(timeout: TimeInterval = 8, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return condition()
    }
}
