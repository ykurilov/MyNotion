import XCTest

/// История версий (US6, quickstart.md): образец с 200 версиями за трое суток (`--generate-versions-sample`) и своя правка
/// с ускоренной записью (`--versions-quick`) → «•••» → «История версий»; группировка; раскрытие версии; ранняя версия с подсветкой →
/// «Восстановить» → «Восстановить эту версию» → полоса «Страница восстановлена»; ⌘Z — как было; Esc закрывает.
final class VersionHistoryTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testHistoryRestoreAndUndo() throws {
        let library = try UITestLibrary.make(for: self)
        let app = XCUIApplication()
        app.launchArguments = ["--database", library.databaseURL.path, "--generate-versions-sample", "--versions-quick",
                               "-MyNotion.recentColors", "", "-NSWindow Frame pages-AppWindow-1", UITestLibrary.startWindowFrame]
        app.launch()
        let row = app.outlines["page-tree"].outlineRows.containing(NSPredicate(format: "value == %@", "Замер: история версий")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Нет страницы образца истории")
        row.click()
        XCTAssertTrue(waitFor { bodyText(app).contains("Абзац 1:") },
                      "Страница образца не открылась: путь «\(app.staticTexts["page-breadcrumb"].exists ? app.staticTexts["page-breadcrumb"].label : "-")», текст «\(bodyText(app).prefix(120))», текстов \(app.textViews.count)")

        // Своя правка: в конец страницы.
        app.pageBody.click()
        app.typeKey(.downArrow, modifierFlags: .command)
        app.typeText(" правка теста")
        XCTAssertTrue(waitFor { bodyText(app).contains("правка теста") })

        openHistory(app)
        let rows = app.descendants(matching: .any).matching(identifier: "version-row")
        XCTAssertTrue(waitFor { rows.count >= 10 }, "Мало строк при «1 минута»: \(rows.count)")
        XCTAssertTrue(app.staticTexts["Текущая версия"].exists, "У самой новой нет метки «Текущая версия»")
        XCTAssertFalse(app.descendants(matching: .any)["version-begin-restore"].isEnabled, "«Восстановить» у текущей включена")
        let firstPreviewTime = textOf(app.staticTexts["version-preview-time"])
        XCTAssertFalse(firstPreviewTime.isEmpty, "Нет строки времени версии")

        // Группировка «1 час»: вторая строка — уже не соседняя минута, а прошлый час; обратно «1 минута».
        let secondByMinute = rowTime(rows, 1)
        XCTAssertFalse(secondByMinute.isEmpty, "Не прочитать время строки")
        chooseGrouping(app, "version-grouping-60")
        XCTAssertTrue(waitFor { rowTime(rows, 1) != secondByMinute }, "«1 час» не объединил версии: \(secondByMinute)")
        chooseGrouping(app, "version-grouping-1")
        XCTAssertTrue(waitFor { rowTime(rows, 1) == secondByMinute })
        let minuteRows = rows.count

        // Прошлая версия: другая строка времени, «Восстановить» включена; раскрытие — что менялось.
        rows.element(boundBy: 5).coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).click()
        let restore = app.descendants(matching: .any)["version-begin-restore"]
        XCTAssertTrue(waitFor { restore.isEnabled }, "«Восстановить» не включилась у прошлой версии")
        XCTAssertNotEqual(textOf(app.staticTexts["version-preview-time"]), firstPreviewTime)
        tap(app.descendants(matching: .any)["version-expand"].firstMatch)
        XCTAssertTrue(app.descendants(matching: .any)["version-changes"].waitForExistence(timeout: 5), "Раскрытие не показало изменения")
        add(XCTAttachment(screenshot: app.screenshot()))
        tap(app.descendants(matching: .any)["version-all-versions"].firstMatch)
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))

        // «Восстановить» → окно «Что будет восстановлено» → «Восстановить эту версию».
        tap(restore)
        let confirm = app.descendants(matching: .any)["version-restore-confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Окно «Что будет восстановлено» не открылось")
        XCTAssertTrue(app.staticTexts["Что будет восстановлено"].exists)
        tap(confirm)
        XCTAssertTrue(app.descendants(matching: .any)["version-restored-banner"].waitForExistence(timeout: 5), "Нет полосы «Страница восстановлена»")
        XCTAssertFalse(app.descendants(matching: .any)["version-history"].exists, "История не закрылась после восстановления")
        XCTAssertTrue(waitFor { !bodyText(app).contains("правка теста") }, "Страница не стала как в прошлой версии")
        add(XCTAttachment(screenshot: app.screenshot()))

        // ⌘Z — страница как до восстановления.
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(waitFor { bodyText(app).contains("правка теста") }, "⌘Z не вернул страницу")

        // История снова открывается, версии на месте; Esc закрывает.
        openHistory(app)
        XCTAssertTrue(waitFor { rows.count >= minuteRows && rows.element(boundBy: 1).exists }, "Версии пропали после восстановления: \(rows.count)")
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
        tap(app.descendants(matching: .any)["version-grouping"].firstMatch)
        let item = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "Нет пункта группировки \(identifier)")
        tap(item)
    }

    /// Щелчок по точке: окно истории — SwiftUI поверх видов AppKit, и XCUITest считает его кнопки «не нажимаемыми»,
    /// хотя мышь до них доходит.
    @MainActor
    private func tap(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 5), "Нет \(element)")
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    }

    /// Время строки списка (первый текст строки).
    @MainActor
    private func rowTime(_ rows: XCUIElementQuery, _ index: Int) -> String {
        textOf(rows.element(boundBy: index).staticTexts.firstMatch)
    }

    /// Текст надписи SwiftUI: в `value`, у некоторых — в `label`.
    @MainActor
    private func textOf(_ element: XCUIElement) -> String {
        guard element.exists else { return "" }
        return (element.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? element.label
    }

    @MainActor
    private func bodyText(_ app: XCUIApplication) -> String {
        let body = app.pageBody
        return body.exists ? body.value as? String ?? "" : ""
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
