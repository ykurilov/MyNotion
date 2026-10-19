import SQLite3
import XCTest

/// Структурные блоки вживую (US1, Independent Test): переключатель «> », цитата «" », разделитель «---», выноска через «/»,
/// вложенность Enter и Tab, свёртывание ⌘Enter переживает перезапуск, ⌘Z рядом со свёрнутым, поиск страниц раскрывает
/// свёрнутое до найденного. Логика каждого шага — в модульных тестах PageEditorTests; здесь — что части работают вместе.
final class StructuralBlocksTests: XCTestCase {
    private var library: UITestLibrary!

    override func setUpWithError() throws {
        continueAfterFailure = false
        library = try UITestLibrary.make(for: self)
    }

    @MainActor
    func testStructuralBlocksNestCollapseSurviveRelaunchAndRevealFromSearch() throws {
        var app = library.launchApp()
        app.createPage(titled: "Структура")
        app.typeText("> Раскрыть")
        app.typeKey(.return, modifierFlags: [])
        app.typeText("секретное слово")
        app.typeKey(.return, modifierFlags: [])
        // Пустой ребёнок: Enter выходит на уровень выше.
        app.typeKey(.return, modifierFlags: [])
        app.typeText("\" Мысль")
        app.typeKey(.return, modifierFlags: [])
        app.typeText("---")
        app.typeText("/выноска")
        XCTAssertTrue(app.popupItem("callout").waitForExistence(timeout: 5), "Меню «/» не нашло выноску")
        app.typeKey(.return, modifierFlags: [])
        app.typeText("Совет")
        app.typeKey(.return, modifierFlags: [])
        app.typeText("внутри выноски")
        app.typeKey(.return, modifierFlags: [])
        app.typeText("ещё")
        app.typeKey(.tab, modifierFlags: .shift)
        app.typeKey(.tab, modifierFlags: [])

        // Свернуть переключатель: курсор в начало страницы, ⌘Enter.
        app.typeKey(.upArrow, modifierFlags: .command)
        app.typeKey(.return, modifierFlags: .command)
        // ⌘Z правки рядом со свёрнутым не трогает свёрнутость.
        app.typeKey(.downArrow, modifierFlags: .command)
        app.typeText("x")
        app.typeKey("z", modifierFlags: .command)

        app.quit()
        let expected: [UITestLibrary.SavedBlock] = [
            .init(kind: "toggle", text: "Раскрыть"),
            .init(kind: "paragraph", text: "секретное слово", indent: 1),
            .init(kind: "quote", text: "Мысль"),
            .init(kind: "divider", text: ""),
            .init(kind: "callout", text: "Совет"),
            .init(kind: "paragraph", text: "внутри выноски", indent: 1),
            .init(kind: "paragraph", text: "ещё", indent: 1),
        ]
        XCTAssertEqual(try library.savedBlocks(ofPage: "Структура"), expected)
        XCTAssertEqual(try collapsedCount(), 1, "Свёрнутость не записалась")

        // Перезапуск: свёрнуто по-прежнему; поиск страниц по слову внутри свёрнутого раскрывает его.
        app = library.launchApp()
        XCTAssertTrue(app.pageBody.waitForExistence(timeout: 10))
        app.createPage(titled: "Другая")
        app.typeKey("f", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.textFields["sidebar-search"].waitForExistence(timeout: 5), "Нет поля поиска")
        app.typeText("секретн")
        let results = app.descendants(matching: .any)["search-results-list"]
        XCTAssertTrue(results.waitForExistence(timeout: 5), "Выдача не появилась")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitUntil { (app.pageTitle.value as? String) == "Структура" }, "Не открылась страница с найденным")
        XCTAssertTrue(waitUntil { (try? self.collapsedCount()) == 0 }, "Переход к найденному не раскрыл переключатель")
        app.quit()
        XCTAssertEqual(try collapsedCount(), 0)
    }

    /// Свёрнутые переключатели в базе этого Mac.
    private func collapsedCount() throws -> Int {
        var database: OpaquePointer?
        guard sqlite3_open_v2(library.databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw UITestLibrary.SQLiteFailure(message: "база не открылась")
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        let sql = "SELECT COUNT(*) FROM block_view_state JOIN block ON block.id = block_view_state.blockId WHERE isCollapsed = 1"
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
