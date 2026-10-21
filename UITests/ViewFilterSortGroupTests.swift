import SQLite3
import XCTest

/// Вид базы вживую (T079, spec US3) на эталоне 10 000 строк: фильтр «Статус не Готово», сортировка по сроку, поиск «отчёт»,
/// скрыть три колонки, группировка по статусу, второй вид «Все» без фильтра; перезапуск — у каждого вида свои настройки.
/// Сетка рисуется сама: шапка колонок — по местам от рамки сетки (у вида «Таблица» эталона все колонки по 200).
final class ViewFilterSortGroupTests: XCTestCase {
    private var library: UITestLibrary!
    static let header: CGFloat = 33, columnWidth: CGFloat = 200

    override func setUpWithError() throws {
        continueAfterFailure = false
        library = try UITestLibrary.make(for: self)
    }

    @MainActor
    func testFilterSortSearchHideGroupSecondViewAndRelaunch() throws {
        var app = library.launchApp(arguments: ["--generate-004-sample"])
        let tasks = app.outlines["page-tree"].outlineRows.containing(NSPredicate(format: "value == %@", "Задачи")).firstMatch
        XCTAssertTrue(tasks.waitForExistence(timeout: 120), "Эталона «Задачи» нет в дереве")
        tasks.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        let grid = app.descendants(matching: .any).matching(identifier: "database-grid").element(boundBy: 0)
        XCTAssertTrue(grid.waitForExistence(timeout: 20), "Таблица не открылась")
        let any = { (id: String) in app.descendants(matching: .any)[id] }

        // Фильтр: воронка → «Статус» → «Не равно» → «Готово».
        any("database-view-bar-filter").click()
        XCTAssertTrue(any("filter-by-Статус").waitForExistence(timeout: 5), "Нет списка «Фильтр по…»")
        any("filter-by-Статус").click()
        XCTAssertTrue(any("filter-operator").waitForExistence(timeout: 5), "Окно плашки не открылось")
        any("filter-operator").click()
        XCTAssertTrue(any("filter-op-isNot").waitForExistence(timeout: 5))
        any("filter-op-isNot").click()
        XCTAssertTrue(any("filter-option-Готово").waitForExistence(timeout: 5), "Нет варианта «Готово»")
        any("filter-option-Готово").click()
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil { (try? self.view("Таблица", "filter"))?.contains("isNot") == true }, "Фильтр не записан")
        XCTAssertTrue(any("database-chip-filter").waitForExistence(timeout: 5), "Нет плашки фильтра")

        // Сортировка: ⇅ → «Срок».
        any("database-view-bar-sort").click()
        XCTAssertTrue(any("sort-by-Срок").waitForExistence(timeout: 5), "Нет списка «Сортировать по…»")
        any("sort-by-Срок").click()
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil { (try? self.view("Таблица", "sorts"))?.contains("ascending") == true }, "Сортировка не записана")

        // Поиск «отчёт»: поле в строке вида, Esc закрывает.
        any("database-view-bar-search").click()
        XCTAssertTrue(any("database-search-field").waitForExistence(timeout: 5), "Поле поиска не раскрылось")
        app.typeText("отчёт")
        XCTAssertTrue(any("database-search-field").exists)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil { !any("database-search-field").exists }, "Esc не закрыл поиск")

        // Скрыть три колонки: меню колонки → «Скрыть» (после каждой следующая встаёт на место скрытой).
        for _ in 0..<3 {
            grid.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: Self.columnWidth + 60, dy: Self.header / 2)).click()
            XCTAssertTrue(any("column-menu-hide").waitForExistence(timeout: 5), "Нет «Скрыть» в меню колонки")
            any("column-menu-hide").click()
        }
        XCTAssertTrue(waitUntil { (try? self.hiddenCount("Таблица")) == 3 }, "Скрыто: \(String(describing: try? hiddenCount("Таблица")))")

        // Группировка: настройки вида → «Группировка» → «Статус».
        any("database-view-bar-settings").click()
        XCTAssertTrue(any("view-settings-group").waitForExistence(timeout: 5), "Нет настроек вида")
        any("view-settings-group").click()
        XCTAssertTrue(any("group-by").waitForExistence(timeout: 5))
        any("group-by").click()
        XCTAssertTrue(any("group-by-Статус").waitForExistence(timeout: 5))
        any("group-by-Статус").click()
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil { (try? self.view("Таблица", "group"))?.contains("propertyId") == true }, "Группировка не записана")

        // Второй вид «Все»: «+» в строке видов, имя в настройках.
        any("database-view-add").click()
        XCTAssertTrue(any("view-settings-name").waitForExistence(timeout: 5), "Настройки нового вида не открылись")
        app.typeKey("a", modifierFlags: .command)
        app.typeText("Все")
        app.typeKey(.return, modifierFlags: [])
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil { (try? self.viewNames())?.contains("Все") == true }, "Виды: \(String(describing: try? viewNames()))")

        app.quit()
        XCTAssertNil(try view("Все", "filter").nilIfNull, "У «Все» не должно быть фильтра")
        XCTAssertEqual(try hiddenCount("Все"), 0)

        // Перезапуск: настройки видов на месте, приложение открывает базу.
        app = library.launchApp()
        XCTAssertTrue(app.descendants(matching: .any)["database-page"].waitForExistence(timeout: 20), "После перезапуска база не открыта")
        app.quit()
        XCTAssertTrue(try view("Таблица", "filter").contains("isNot"))
        XCTAssertTrue(try view("Таблица", "group").contains("propertyId"))
        XCTAssertEqual(try hiddenCount("Таблица"), 3)
    }

    // MARK: Помощники

    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return condition()
    }

    private func query(_ sql: String, _ arguments: [String]) throws -> [[String]] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(library.databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw Failure.open }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw Failure.sql(String(cString: sqlite3_errmsg(database))) }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, argument) in arguments.enumerated() { sqlite3_bind_text(statement, Int32(index + 1), argument, -1, transient) }
        var rows: [[String]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append((0..<sqlite3_column_count(statement)).map { sqlite3_column_text(statement, $0).map { String(cString: $0) } ?? "" })
        }
        return rows
    }

    private enum Failure: Error { case open, sql(String) }

    private static let tasks = "(SELECT id FROM page WHERE title = 'Задачи' AND parentId IS NULL AND trashedAt IS NULL AND id IN (SELECT pageId FROM db_database))"

    /// Поле вида базы «Задачи» по имени вида (`filter`, `sorts`, `group`, `columns`).
    private func view(_ name: String, _ field: String) throws -> String {
        try query("SELECT COALESCE(\(field), '') FROM db_view WHERE databaseId = \(Self.tasks) AND name = ? LIMIT 1", [name]).first?.first ?? ""
    }

    private func hiddenCount(_ name: String) throws -> Int {
        try view(name, "columns").components(separatedBy: "\"isVisible\":false").count - 1
    }

    private func viewNames() throws -> [String] {
        try query("SELECT name FROM db_view WHERE databaseId = \(Self.tasks) AND json_extract(layoutOptions, '$.deletedAt') IS NULL ORDER BY sortKey",
                  []).map { $0[0] }
    }
}

private extension String {
    var nilIfNull: String? { isEmpty || self == "null" ? nil : self }
}
