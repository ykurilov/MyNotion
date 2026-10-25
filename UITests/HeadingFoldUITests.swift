import SQLite3
import XCTest

/// Свёртывание заголовка вживую: стрелка в ручках вместо «+» сворачивает и разворачивает раздел, свёрнутость
/// переживает перезапуск. Логика раздела, подписи и Enter — в модульных тестах HeadingFoldTests.
final class HeadingFoldUITests: XCTestCase {
    private var library: UITestLibrary!

    override func setUpWithError() throws {
        continueAfterFailure = false
        library = try UITestLibrary.make(for: self)
    }

    @MainActor
    func testFoldHeadingExpandAndReopen() throws {
        var app = library.launchApp()
        app.createPage(titled: "Разделы")
        app.typeText("## Раздел")
        app.typeKey(.return, modifierFlags: [])
        app.typeText("спрятанный текст")
        app.typeKey(.return, modifierFlags: [])
        app.typeText("## Следующий")

        XCTAssertTrue(app.hoverFirstBlock(), "Ручки заголовка не появились")
        let fold = app.blockFoldHandle
        XCTAssertTrue(fold.exists, "У заголовка нет стрелки вместо «+»")
        XCTAssertEqual(fold.label, "Свернуть")
        fold.click()
        XCTAssertTrue(waitUntil { (try? self.collapsedCount()) == 1 }, "Свёрнутость не записалась")
        XCTAssertEqual(fold.label, "Развернуть")
        fold.click()
        XCTAssertTrue(waitUntil { (try? self.collapsedCount()) == 0 }, "Стрелка не развернула")
        fold.click()
        XCTAssertTrue(waitUntil { (try? self.collapsedCount()) == 1 })
        app.quit()
        XCTAssertEqual(try library.savedBlocks(ofPage: "Разделы").map(\.text), ["Раздел", "спрятанный текст", "Следующий"],
                       "Свёртывание потеряло текст")

        // Перезапуск: заголовок свёрнут по-прежнему, стрелка разворачивает.
        app = library.launchApp()
        XCTAssertTrue(app.pageBody.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil { (app.pageTitle.value as? String) == "Разделы" }, "Страница не открылась снова")
        XCTAssertTrue(app.hoverFirstBlock(), "Ручки заголовка не появились после перезапуска")
        XCTAssertEqual(app.blockFoldHandle.label, "Развернуть", "После перезапуска заголовок не свёрнут")
        app.blockFoldHandle.click()
        XCTAssertTrue(waitUntil { (try? self.collapsedCount()) == 0 }, "После перезапуска стрелка не развернула")
        app.quit()
    }

    /// Свёрнутые блоки в базе этого Mac.
    private func collapsedCount() throws -> Int {
        var database: OpaquePointer?
        guard sqlite3_open_v2(library.databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw UITestLibrary.SQLiteFailure(message: "база не открылась")
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        let sql = "SELECT COUNT(*) FROM block_view_state WHERE isCollapsed = 1"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw UITestLibrary.SQLiteFailure(message: String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(statement, 0))
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }
}
