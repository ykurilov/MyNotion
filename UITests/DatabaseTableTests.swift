import SQLite3
import XCTest

/// Таблица базы вживую (T034, spec US1): «/База данных — встроенная» и «— на всю страницу»; колонки числа и флажка;
/// 20 строк; правка, Enter, Tab, Esc; выделение и ⌘C/⌘V; строка «ОТКРЫТЬ» сбоку; ⌘Z по шагам; перезапуск — всё на месте.
/// Сетка рисуется сама (не элементы доступности), поэтому щелчки — по местам ячеек от рамки сетки: шапка и строка — по 33,
/// «Название» — 280, остальные колонки — 200 (contracts/database-ui.md).
final class DatabaseTableTests: XCTestCase {
    private var library: UITestLibrary!
    static let header: CGFloat = 33, rowHeight: CGFloat = 33, titleWidth: CGFloat = 280, columnWidth: CGFloat = 200

    override func setUpWithError() throws {
        continueAfterFailure = false
        library = try UITestLibrary.make(for: self)
    }

    @MainActor
    func testTableEditingSelectionClipboardUndoAndRelaunch() throws {
        var app = library.launchApp()
        app.createPage(titled: "Проект")
        app.typeText("/встроенная")
        XCTAssertTrue(app.popupItem("database-inline").waitForExistence(timeout: 5), "В «/» нет встроенной базы")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.descendants(matching: .any)["database-inline"].waitForExistence(timeout: 5), "Встроенная база не появилась")

        // Полностраничная база: открывается сразу, курсор в названии.
        app.createPage(titled: "Работа")
        app.typeText("/на всю")
        XCTAssertTrue(app.popupItem("database-full-page").waitForExistence(timeout: 5), "В «/» нет базы на всю страницу")
        app.typeKey(.return, modifierFlags: [])
        let grid = app.descendants(matching: .any).matching(identifier: "database-grid").element(boundBy: 0)
        XCTAssertTrue(app.descendants(matching: .any)["database-page"].waitForExistence(timeout: 5), "Страница-база не открылась")
        app.typeText("Задачи")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(grid.waitForExistence(timeout: 5))

        // Колонки: «+» в шапке — имя и тип.
        addColumn(app, grid: grid, index: 1, name: "Часы", type: "number")
        addColumn(app, grid: grid, index: 2, name: "Готово", type: "checkbox")
        XCTAssertTrue(waitUntil { (try? self.properties("Задачи")) == ["Название", "Часы", "Готово"] }, "Свойства: \(String(describing: try? properties("Задачи")))")

        // Первая строка — «+ Новая строка», название, Enter; ещё 19 — вставкой столбика из 20 названий в первую строку
        // (⌘V за последнюю строку добавляет строки).
        cell(grid, row: 0, x: 40).click()
        XCTAssertTrue(app.textFields["database-cell-editor"].waitForExistence(timeout: 5), "Нет правки названия новой строки")
        app.typeText("Задача 1")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitUntil { (try? self.rowTitles("Задачи")) == ["Задача 1"] }, "Строки: \(String(describing: try? rowTitles("Задачи")))")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString((1...20).map { "Задача \($0)" }.joined(separator: "\n"), forType: .string)
        cell(grid, row: 0).click()
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey("v", modifierFlags: .command)
        XCTAssertTrue(waitUntil(timeout: 10) { (try? self.rowTitles("Задачи").count) == 20 }, "Строк: \(String(describing: try? rowTitles("Задачи").count))")

        // Число: щелчок — правка, Tab — вправо; Esc — готово, ячейка выбрана.
        cell(grid, row: 0, column: 1).click()
        app.typeText("5")
        app.typeKey(.tab, modifierFlags: [])
        cell(grid, row: 1, column: 1).click()
        app.typeText("7")
        app.typeKey(.escape, modifierFlags: [])
        // Флажок — щелчок по квадрату.
        cell(grid, row: 0, column: 2, x: 16).click()
        XCTAssertTrue(waitUntil { (try? self.values("Задачи", "Часы").prefix(2)) == ["5", "7"] }, "Часы: \(String(describing: try? values("Задачи", "Часы")))")
        XCTAssertTrue(waitUntil { (try? self.values("Задачи", "Готово").first) == "1" }, "Флажок: \(String(describing: try? values("Задачи", "Готово")))")

        // Выделение ⇧-щелчком, ⌘C, ⌘V двумя строками ниже.
        cell(grid, row: 0, column: 1).click()
        app.typeKey(.escape, modifierFlags: [])
        XCUIElement.perform(withKeyModifiers: .shift) { cell(grid, row: 1, column: 1).click() }
        app.typeKey("c", modifierFlags: .command)
        cell(grid, row: 2, column: 1).click()
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey("v", modifierFlags: .command)
        XCTAssertTrue(waitUntil { (try? self.values("Задачи", "Часы").prefix(4)) == ["5", "7", "5", "7"] },
                      "После ⌘V: \(String(describing: try? values("Задачи", "Часы")))")

        // ⌘Z — вставка уходит одним шагом, ⇧⌘Z возвращает.
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(waitUntil { (try? self.values("Задачи", "Часы").prefix(4)) == ["5", "7", "", ""] }, "После ⌘Z: \(String(describing: try? values("Задачи", "Часы")))")
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitUntil { (try? self.values("Задачи", "Часы").prefix(4)) == ["5", "7", "5", "7"] }, "После ⇧⌘Z")

        // «ОТКРЫТЬ» у названия при наведении — строка сбоку, Esc закрывает.
        cell(grid, row: 3, x: 120).hover()
        let open = app.buttons["database-row-open"]
        XCTAssertTrue(open.waitForExistence(timeout: 5), "Нет «ОТКРЫТЬ» при наведении")
        open.click()
        XCTAssertTrue(app.descendants(matching: .any)["row-side-peek"].waitForExistence(timeout: 5), "Строка не открылась сбоку")
        XCTAssertTrue(app.descendants(matching: .any)["row-properties"].waitForExistence(timeout: 5), "Нет свойств под названием строки")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil { !app.descendants(matching: .any)["row-side-peek"].exists }, "Esc не закрыл просмотр")

        app.quit()
        XCTAssertEqual(try rowTitles("Задачи"), (1...20).map { "Задача \($0)" })
        XCTAssertEqual(Array(try values("Задачи", "Часы").prefix(4)), ["5", "7", "5", "7"])

        // Перезапуск: база и строки на месте.
        app = library.launchApp()
        XCTAssertTrue(app.descendants(matching: .any)["database-page"].waitForExistence(timeout: 10), "После перезапуска база не открыта")
        app.quit()
        XCTAssertEqual(try rowTitles("Задачи").count, 20)
    }

    // MARK: Помощники

    @MainActor
    private func cell(_ grid: XCUIElement, row: Int, column: Int = 0, x: CGFloat? = nil) -> XCUICoordinate {
        let left = column == 0 ? 0 : Self.titleWidth + CGFloat(column - 1) * Self.columnWidth
        return grid.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: left + (x ?? 60), dy: Self.header + CGFloat(row) * Self.rowHeight + Self.rowHeight / 2))
    }

    /// «+» в шапке после последней колонки: имя, тип.
    @MainActor
    private func addColumn(_ app: XCUIApplication, grid: XCUIElement, index: Int, name: String, type: String) {
        let plusX = Self.titleWidth + CGFloat(index - 1) * Self.columnWidth + 16
        grid.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: plusX, dy: Self.header / 2)).click()
        let field = app.descendants(matching: .any)["add-property-name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Нет поля имени нового свойства")
        app.typeText(name)
        let item = app.descendants(matching: .menuItem)["property-type-\(type)"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "Нет типа \(type)")
        item.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        app.typeKey(.escape, modifierFlags: [])
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }

    // MARK: База

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

    private static let base = "(SELECT id FROM page WHERE title = ? AND trashedAt IS NULL AND id IN (SELECT pageId FROM db_database))"

    private func properties(_ database: String) throws -> [String] {
        try query("SELECT name FROM db_property WHERE databaseId = \(Self.base) AND deletedAt IS NULL ORDER BY sortKey", [database]).map { $0[0] }
    }

    /// Названия строк по месту в виде (ручного порядка в сценарии нет — место страницы).
    private func rowTitles(_ database: String) throws -> [String] {
        try query("SELECT title FROM page WHERE parentId = \(Self.base) AND trashedAt IS NULL ORDER BY sortKey", [database]).map { $0[0] }
    }

    /// Значения свойства по строкам в порядке строк; пусто — "".
    private func values(_ database: String, _ property: String) throws -> [String] {
        try query("""
            SELECT COALESCE(c.value, '') FROM page p
            LEFT JOIN db_cell c ON c.rowId = p.id AND c.propertyId = (SELECT id FROM db_property WHERE name = ? AND databaseId = \(Self.base))
            WHERE p.parentId = \(Self.base) AND p.trashedAt IS NULL ORDER BY p.sortKey
            """, [property, database, database]).map { $0[0] == "true" ? "1" : $0[0] }
    }
}
