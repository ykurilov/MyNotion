import SQLite3
import XCTest

/// Упоминания, даты и напоминания (US3, Independent Test): упомянуть страницу, переименовать её — упоминание
/// обновилось; дата «завтра» с напоминанием — уведомление macOS отдано системе и отмечено показанным.
/// Баннер macOS 26 в дерево доступности не попадает, поэтому щелчок по нему тест не делает: открытие страницы
/// у блока — `PagesLibrary.openBlock`; синтетический щелчок по телу баннера в виртуальном Mac не срабатывает.
/// Время напоминания не ждётся по-настоящему: часы напоминаний приложения сдвинуты вперёд
/// (`--reminders-clock-offset`), и напоминание уже «пропущено во сне» — система показывает его сразу.
final class MentionsAndDatesTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testMentionFollowsRenameAndOpensPage() throws {
        let library = try UITestLibrary.make(for: self)
        let app = library.launchApp()
        app.createPage(titled: "Цель")
        app.typeText("главная")
        app.createPage(titled: "Заметки")
        app.typeText("Смотри @Це")
        let row = app.descendants(matching: .menuItem).matching(NSPredicate(format: "identifier BEGINSWITH 'mention-page-'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Окно «@» не показало страницу")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitForBody(app) { $0 == "Смотри Цель" }, "В тексте: \(app.pageBodyValue)")

        // Щелчок по упоминанию открывает страницу.
        XCTAssertTrue(clickAtom(app, line: 0, startX: 60) { app.pageTitle.value as? String == "Цель" }, "Упоминание не открыло страницу")
        app.pageTitle.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeText("Цель года")
        app.typeKey(.return, modifierFlags: [])

        app.typeKey("f", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.textFields["sidebar-search"].waitForExistence(timeout: 5), "Нет поля поиска")
        app.typeText("Заметки")
        XCTAssertTrue(app.descendants(matching: .any)["search-results-list"].waitForExistence(timeout: 5), "Выдача не появилась")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitFor { app.pageTitle.value as? String == "Заметки" }, "Не открылись «Заметки»")
        XCTAssertTrue(waitForBody(app) { $0 == "Смотри Цель года" }, "Упоминание не обновилось: \(app.pageBodyValue)")
        app.quit()
        XCTAssertTrue(try library.savedTextStyles(ofPage: "Заметки").joined().contains("\"mention\""))
    }

    @MainActor
    func testReminderIsDelivered() throws {
        let library = try UITestLibrary.make(for: self)
        let app = XCUIApplication()
        // Двое суток вперёд: напоминание «завтра» уже прошло, но не старше 7 дней — показывается сразу.
        app.launchArguments = ["--database", library.databaseURL.path, "--reminders-clock-offset", "172800"]
        app.launch()
        app.createPage(titled: "Созвоны")
        app.typeText("@завтра")
        app.typeKey(.return, modifierFlags: [])
        // Доступность читает дату словами без «завтра»: «@20 октября 2026».
        XCTAssertTrue(waitForBody(app) { $0.hasPrefix("@") && !$0.contains("завтра") },
                      "Дата не вставилась: \(app.pageBodyValue)")

        // Щелчок по дате — календарик; «Напомнить» → «В момент события».
        let reminder = app.buttons["date-picker-reminder"]
        XCTAssertTrue(clickAtom(app, line: 0, startX: 20) { reminder.exists }, "Календарик не открылся")
        reminder.click()
        app.menuItems["В момент события"].click()
        allowNotificationsIfAsked()
        app.typeKey(.escape, modifierFlags: [])
        // Набранное уходит в базу, индекс ставит напоминание, планировщик показывает пропущенное сразу.
        app.typeKey(.downArrow, modifierFlags: [])

        XCTAssertTrue(waitFor(timeout: 30) { ((try? self.deliveredAt(in: library)) ?? nil) != nil },
                      "Напоминание не показано: индекс \(String(describing: try? indexRows(in: library)))")
        app.quit()
    }

    // MARK: Помощники

    /// Щёлкать по строке `line` текста вправо от `startX`, пока не выполнится `done` (атом не виден доступности).
    @MainActor
    private func clickAtom(_ app: XCUIApplication, line: Int, startX: CGFloat, until done: () -> Bool) -> Bool {
        let title = app.pageTitle.frame
        let body = app.pageBody
        let origin = body.coordinate(withNormalizedOffset: .zero)
        for dy in stride(from: CGFloat(14), through: 60, by: 8) {
            for dx in stride(from: startX, through: startX + 80, by: 20) {
                let point = CGPoint(x: title.minX + dx, y: title.maxY + dy + CGFloat(line) * 30)
                origin.withOffset(CGVector(dx: point.x - body.frame.minX, dy: point.y - body.frame.minY)).click()
                if waitFor(timeout: 0.7, done) { return true }
            }
        }
        return false
    }

    /// Первое «Напомнить» спрашивает разрешение macOS — разрешить.
    @MainActor
    private func allowNotificationsIfAsked() {
        for bundle in ["com.apple.UserNotificationCenter", "com.apple.notificationcenterui"] {
            let center = XCUIApplication(bundleIdentifier: bundle)
            for title in ["Allow", "Разрешить", "Options", "Параметры"] {
                let button = center.buttons[title]
                if button.waitForExistence(timeout: title == "Allow" ? 5 : 1) {
                    button.click()
                    if title == "Options" || title == "Параметры" {
                        let allow = center.menuItems.matching(NSPredicate(format: "title IN %@", ["Allow", "Разрешить"])).firstMatch
                        if allow.waitForExistence(timeout: 2) { allow.click() }
                    }
                    return
                }
            }
        }
    }

    @MainActor
    private func waitForBody(_ app: XCUIApplication, _ condition: (String) -> Bool) -> Bool {
        waitFor { condition(app.pageBodyValue) }
    }

    @MainActor
    private func waitFor(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    /// Строки индекса напоминаний — для сообщения об ошибке.
    private func indexRows(in library: UITestLibrary) throws -> [String] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(library.databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return ["нет базы"] }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT fireAt || ' / ' || ifnull(deliveredAt, '-') FROM reminder_index", -1, &statement, nil)
            == SQLITE_OK else { return ["нет таблицы"] }
        defer { sqlite3_finalize(statement) }
        var rows: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW { rows.append(String(cString: sqlite3_column_text(statement, 0))) }
        return rows
    }

    private func deliveredAt(in library: UITestLibrary) throws -> String? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(library.databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT deliveredAt FROM reminder_index LIMIT 1", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_text(statement, 0).map { String(cString: $0) }
    }
}

private extension XCUIApplication {
    var pageBodyValue: String { (pageBody.exists ? pageBody.value as? String : nil) ?? "" }
}
