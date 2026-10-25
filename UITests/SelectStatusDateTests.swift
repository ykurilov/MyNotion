import SQLite3
import XCTest

/// Выбор, статус, дата вживую (T068, spec US2): вариант из ячейки по Enter, несколько вариантов множественного выбора,
/// статус с тремя группами по умолчанию, дата текстом с концом и напоминанием за день; перезапуск — всё на месте.
/// Сетка рисуется сама — щелчки по местам ячеек от рамки сетки («Название» 280, строки 33). Новые колонки сужаются
/// протяжкой края до 110: окно на iMac узкое, все колонки должны быть видны.
final class SelectStatusDateTests: XCTestCase {
    private var library: UITestLibrary!
    static let header: CGFloat = 33, rowHeight: CGFloat = 33, titleWidth: CGFloat = 280, columnWidth: CGFloat = 110

    override func setUpWithError() throws {
        continueAfterFailure = false
        library = try UITestLibrary.make(for: self)
    }

    @MainActor
    func testSelectStatusDateAndRelaunch() throws {
        var app = library.launchApp()
        app.createPage(titled: "Работа")
        app.typeText("/на всю")
        XCTAssertTrue(app.popupItem("database-full-page").waitForExistence(timeout: 5), "В «/» нет базы на всю страницу")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.descendants(matching: .any)["database-page"].waitForExistence(timeout: 5), "Страница-база не открылась")
        app.typeText("Задачи")
        app.typeKey(.return, modifierFlags: [])
        let grid = app.descendants(matching: .any).matching(identifier: "database-grid").element(boundBy: 0)
        XCTAssertTrue(grid.waitForExistence(timeout: 5))
        app.activate()

        addColumn(app, grid: grid, index: 1, name: "Тип", type: "select")
        addColumn(app, grid: grid, index: 2, name: "Теги", type: "multiSelect")
        addColumn(app, grid: grid, index: 3, name: "Статус", type: "status")
        addColumn(app, grid: grid, index: 4, name: "Срок", type: "date")
        XCTAssertTrue(waitUntil { (try? self.optionNames("Статус")) == ["В работе", "Готово", "Не начато"] },
                      "Статус по умолчанию: \(String(describing: try? optionNames("Статус")))")

        // Строка.
        cell(grid, row: 0, x: 40).click()
        XCTAssertTrue(app.textFields["database-cell-editor"].waitForExistence(timeout: 5))
        app.typeText("Отчёт")
        app.typeKey(.return, modifierFlags: [])
        app.typeKey(.escape, modifierFlags: [])

        // Выбор: щелчок — окно, набор и Enter создают вариант и выбирают его, окно закрывается.
        cell(grid, row: 0, column: 1).click()
        XCTAssertTrue(app.descendants(matching: .any)["option-search"].waitForExistence(timeout: 5), "Нет окна выбора")
        app.typeText("Баг")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitUntil { (try? self.chosen("Тип")) == ["Баг"] }, "Выбор: \(String(describing: try? chosen("Тип")))")
        XCTAssertTrue(waitUntil { !app.descendants(matching: .any)["option-search"].exists }, "Окно выбора не закрылось")

        // Множественный: два варианта подряд, окно остаётся; Esc закрывает.
        cell(grid, row: 0, column: 2).click()
        XCTAssertTrue(app.descendants(matching: .any)["option-search"].waitForExistence(timeout: 5))
        app.typeText("Срочно")
        app.typeKey(.return, modifierFlags: [])
        app.typeText("Потом")
        app.typeKey(.return, modifierFlags: [])
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil { (try? self.chosen("Теги")) == ["Потом", "Срочно"] }, "Теги: \(String(describing: try? chosen("Теги")))")

        // Статус: щелчок по варианту группы «В работе».
        cell(grid, row: 0, column: 3).click()
        let inProgress = app.descendants(matching: .any)["option-row-В работе"]
        XCTAssertTrue(inProgress.waitForExistence(timeout: 5), "Нет варианта «В работе»")
        inProgress.click()
        XCTAssertTrue(waitUntil { (try? self.chosen("Статус")) == ["В работе"] }, "Статус: \(String(describing: try? chosen("Статус")))")

        // Дата: текстом, «Дата окончания», «Напомнить › За 1 день».
        cell(grid, row: 0, column: 4).click()
        XCTAssertTrue(app.descendants(matching: .any)["date-start-field"].waitForExistence(timeout: 5), "Нет окна даты")
        app.typeText("21.10.2030")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitUntil { (try? self.dateValue())?.contains("\"start\":\"2030-10-21\"") == true }, "Дата: \(String(describing: try? dateValue()))")
        app.descendants(matching: .any)["date-end-toggle"].click()
        app.descendants(matching: .any)["date-remind"].click()
        let dayBefore = app.descendants(matching: .any)["choice-day1"]
        XCTAssertTrue(dayBefore.waitForExistence(timeout: 5), "Нет списка напоминаний")
        dayBefore.click()
        XCTAssertTrue(waitUntil { (try? self.dateValue()).map { $0.contains("\"end\":\"2030-10-21\"") && $0.contains("\"reminder\":\"day1\"") } == true },
                      "Конец и напоминание: \(String(describing: try? dateValue()))")
        app.typeKey(.escape, modifierFlags: [])

        app.quit()
        app = library.launchApp()
        XCTAssertTrue(app.descendants(matching: .any)["database-page"].waitForExistence(timeout: 10), "После перезапуска база не открыта")
        app.quit()
        XCTAssertEqual(try chosen("Тип"), ["Баг"])
        XCTAssertEqual(try chosen("Теги"), ["Потом", "Срочно"])
        XCTAssertEqual(try chosen("Статус"), ["В работе"])
        XCTAssertTrue(try dateValue().contains("\"reminder\":\"day1\""))
    }

    // MARK: Помощники

    @MainActor
    private func cell(_ grid: XCUIElement, row: Int, column: Int = 0, x: CGFloat? = nil) -> XCUICoordinate {
        let left = column == 0 ? 0 : Self.titleWidth + CGFloat(column - 1) * Self.columnWidth
        return grid.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: left + (x ?? 60), dy: Self.header + CGFloat(row) * Self.rowHeight + Self.rowHeight / 2))
    }

    @MainActor
    private func addColumn(_ app: XCUIApplication, grid: XCUIElement, index: Int, name: String, type: String) {
        let plusX = Self.titleWidth + CGFloat(index - 1) * Self.columnWidth + 16
        grid.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: plusX, dy: Self.header / 2)).click()
        XCTAssertTrue(app.descendants(matching: .any)["add-property-name"].waitForExistence(timeout: 5), "Нет поля имени нового свойства")
        app.typeText(name)
        let item = app.descendants(matching: .any)["property-type-\(type)"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "Нет типа \(type)")
        item.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        app.typeKey(.escape, modifierFlags: [])
        // Новая колонка — 200; край тянется до 110.
        let left = Self.titleWidth + CGFloat(index - 1) * Self.columnWidth
        let origin = grid.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: left + 199, dy: Self.header / 2))
            .click(forDuration: 0.2, thenDragTo: origin.withOffset(CGVector(dx: left + Self.columnWidth - 1, dy: Self.header / 2)))
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
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

    private static let base = "(SELECT id FROM page WHERE title = 'Задачи' AND trashedAt IS NULL AND id IN (SELECT pageId FROM db_database))"
    private static func property(_ name: String) -> String { "(SELECT id FROM db_property WHERE name = '\(name)' AND databaseId = \(base))" }

    /// Неудалённые варианты свойства по алфавиту.
    private func optionNames(_ property: String) throws -> [String] {
        try query("SELECT name FROM db_select_option WHERE propertyId = \(Self.property(property)) AND deletedAt IS NULL ORDER BY name", [])
            .map { $0[0] }
    }

    /// Варианты в ячейке первой строки по алфавиту.
    private func chosen(_ property: String) throws -> [String] {
        try query("""
            SELECT o.name FROM db_select_option o JOIN db_cell c ON c.propertyId = o.propertyId
            WHERE o.propertyId = \(Self.property(property)) AND c.rowId = (SELECT id FROM page WHERE parentId = \(Self.base) AND trashedAt IS NULL)
                AND instr(lower(c.value), lower(o.id)) > 0 AND o.deletedAt IS NULL ORDER BY o.name
            """, []).map { $0[0] }
    }

    private func dateValue() throws -> String {
        try query("SELECT value FROM db_cell WHERE propertyId = \(Self.property("Срок"))", []).first?.first ?? ""
    }
}
