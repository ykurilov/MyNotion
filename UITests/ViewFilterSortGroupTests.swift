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
        tap(any("database-view-bar-filter"))
        XCTAssertTrue(any("filter-property-list").waitForExistence(timeout: 5), "Нет списка «Фильтр по…»")
        // Список длинный: «Статус» — ниже видимой части; поиск по списку оставляет его наверху.
        app.typeText("Статус")
        XCTAssertTrue(any("filter-by-Статус").waitForExistence(timeout: 5))
        tap(any("filter-by-Статус"))
        XCTAssertTrue(any("filter-operator").waitForExistence(timeout: 5), "Окно плашки не открылось")
        tap(any("filter-operator"))
        XCTAssertTrue(any("filter-op-isNot").waitForExistence(timeout: 5))
        tap(any("filter-op-isNot"))
        XCTAssertTrue(any("filter-option-Готово").waitForExistence(timeout: 5), "Нет варианта «Готово»")
        tap(any("filter-option-Готово"))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil { (try? self.view("Таблица", "filter"))?.contains("isNot") == true }, "Фильтр не записан")
        XCTAssertTrue(any("database-chip-filter").waitForExistence(timeout: 5), "Нет плашки фильтра")

        // Сортировка: ⇅ → «Срок».
        tap(any("database-view-bar-sort"))
        XCTAssertTrue(any("sort-property-list").waitForExistence(timeout: 5), "Нет списка «Сортировать по…»")
        app.typeText("Срок")
        XCTAssertTrue(any("sort-by-Срок").waitForExistence(timeout: 5))
        tap(any("sort-by-Срок"))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil { (try? self.view("Таблица", "sorts"))?.contains("ascending") == true }, "Сортировка не записана")

        // Поиск «отчёт»: поле в строке вида, Esc закрывает.
        tap(any("database-view-bar-search"))
        XCTAssertTrue(any("database-search-field").waitForExistence(timeout: 5), "Поле поиска не раскрылось")
        app.typeText("отчёт")
        XCTAssertTrue(any("database-search-field").exists)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil { !any("database-search-field").exists }, "Esc не закрыл поиск")

        // Скрыть три колонки: меню колонки → «Скрыть» (после каждой следующая встаёт на место скрытой).
        for _ in 0..<3 {
            grid.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: Self.columnWidth + 60, dy: Self.header / 2)).click()
            XCTAssertTrue(any("column-menu-hide").waitForExistence(timeout: 5), "Нет «Скрыть» в меню колонки")
            tap(any("column-menu-hide"))
        }
        XCTAssertTrue(waitUntil { (try? self.hiddenCount("Таблица")) == 3 }, "Скрыто: \(String(describing: try? hiddenCount("Таблица")))")

        // Группировка: настройки вида → «Группировка» → «Область» (список свойств по алфавиту без поиска — берём видимое;
        // группы по статусу проверяют модульные тесты и замер).
        tap(any("database-view-bar-settings"))
        XCTAssertTrue(any("view-settings-group").waitForExistence(timeout: 5), "Нет настроек вида")
        tap(any("view-settings-group"))
        XCTAssertTrue(any("group-by-Область").waitForExistence(timeout: 5), "Нет списка «Группировать по»")
        tap(any("group-by-Область"))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil { (try? self.view("Таблица", "group"))?.contains("propertyId") == true }, "Группировка не записана")

        // Второй вид «Все»: «+» в строке видов, имя в настройках.
        tap(any("database-view-add"))
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

    /// Щелчок по середине: кнопки строки вида и пункты окон открывают карточки, а не меню — ожидание меню XCUITest не нужно.
    @MainActor
    private func tap(_ element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    }

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
