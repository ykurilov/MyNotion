import SQLite3
import XCTest

/// Связи и сводки вживую (T089, spec US4): у «Задач» новая связь «Проект» с «Проектами» и ответным свойством «Задачи»;
/// окно ячейки связи — выбор строки и «Создать «Отпуск»» (строка появляется в «Проектах»); у «Проектов» сводка «Часов»
/// (Задачи → Часы → Сумма) считает сразу; правка часов задачи — сводка пересчитана. Логика и встречные правки —
/// `RelationOperationsTests`, `RollupRecomputeTests`, `RelationLinkMergeTests`.
final class RelationRollupTests: XCTestCase {
    private var library: UITestLibrary!
    static let header: CGFloat = 33, rowHeight: CGFloat = 33, titleWidth: CGFloat = 280, columnWidth: CGFloat = 200

    override func setUpWithError() throws {
        continueAfterFailure = false
        library = try UITestLibrary.make(for: self)
    }

    /// Запуск на той же базе с открытой базой `opening` (переход щелчком в дереве ломают чужие системные окна поверх).
    @MainActor
    private func launch(opening: String = "Задачи") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--database", library.databaseURL.path, "--relations-demo", "--relations-demo-open", opening,
                               "-NSWindow Frame pages-AppWindow-1", UITestLibrary.startWindowFrame]
        app.launch()
        return app
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    @MainActor
    func testRelationPickerCreateRowAndRollup() throws {
        var app = launch()
        var grid = app.descendants(matching: .any).matching(identifier: "database-grid").element(boundBy: 0)
        XCTAssertTrue(grid.waitForExistence(timeout: 30), "«Задачи» не открылись")
        XCTAssertTrue(waitUntil { (try? self.rowTitles("Задачи")) == ["Позвонить", "Купить", "Сдать отчёт"] })

        // Новая связь: «+», имя, тип «Связь» — сразу панель «Изменить свойство»; «Связана с» → «Проекты»; ответное свойство.
        addColumn(app, grid: grid, index: 2, name: "Проект", type: "relation")
        let target = element(app, "relation-target")
        XCTAssertTrue(target.waitForExistence(timeout: 5), "Панель связи не открылась")
        target.click()
        let projectsId = try XCTUnwrap(try databaseId("Проекты"))
        let choice = element(app, "relation-target-\(projectsId)")
        XCTAssertTrue(choice.waitForExistence(timeout: 5), "Нет «Проектов» в окне «Связать с базой»")
        choice.click()
        XCTAssertTrue(waitUntil { (try? self.config("Задачи", "Проект"))?.contains(projectsId) == true }, "Связь не настроена")
        let toggle = element(app, "relation-related-toggle")
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.click()
        XCTAssertTrue(waitUntil { (try? self.properties("Проекты")) == ["Название", "Задачи"] }, "Нет ответного свойства")
        app.typeKey(.escape, modifierFlags: [])

        // Окно ячейки связи: выбрать «Дом», затем создать «Отпуск».
        cell(grid, row: 0, column: 2).click()
        let search = element(app, "relation-picker-search")
        XCTAssertTrue(search.waitForExistence(timeout: 5), "Окно связи не открылось")
        app.typeText("Дом")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitUntil { (try? self.links("Позвонить")) == ["Дом"] }, "Связь: \(String(describing: try? links("Позвонить")))")
        app.typeText("Отпуск")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitUntil { (try? self.rowTitles("Проекты")) == ["Дом", "Работа", "Отпуск"] }, "Строка в «Проектах» не создана")
        XCTAssertTrue(waitUntil { (try? self.links("Позвонить")) == ["Дом", "Отпуск"] })
        app.typeKey(.escape, modifierFlags: [])
        cell(grid, row: 1, column: 2).click()
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        app.typeText("Дом")
        app.typeKey(.return, modifierFlags: [])
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil { (try? self.links("Купить")) == ["Дом"] })

        // ⌘Z снимает последнюю связь.
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(waitUntil { (try? self.links("Купить")) == [] }, "⌘Z не снял связь")
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitUntil { (try? self.links("Купить")) == ["Дом"] })

        // «Проекты»: сводка «Часов» — Задачи → Часы → Сумма.
        app.terminate()
        app = launch(opening: "Проекты")
        grid = app.descendants(matching: .any).matching(identifier: "database-grid").element(boundBy: 0)
        XCTAssertTrue(grid.waitForExistence(timeout: 30), "«Проекты» не открылись")
        addColumn(app, grid: grid, index: 2, name: "Часов", type: "rollup")
        let pairedId = try XCTUnwrap(try propertyId("Проекты", "Задачи"))
        let hoursId = try XCTUnwrap(try propertyId("Задачи", "Часы"))
        for (row, item) in [("rollup-relation", "rollup-relation-\(pairedId)"), ("rollup-target", "rollup-target-\(hoursId)"),
                            ("rollup-calculation", "rollup-calculation-sum")] {
            let button = element(app, row)
            XCTAssertTrue(button.waitForExistence(timeout: 5), "Нет строки \(row)")
            button.click()
            let option = element(app, item)
            XCTAssertTrue(option.waitForExistence(timeout: 5), "Нет пункта \(item)")
            option.click()
        }
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil(timeout: 10) { (try? self.computed("Проекты", "Часов", row: "Дом")) == "5" },
                      "Сводка: \(String(describing: try? computed("Проекты", "Часов", row: "Дом")))")
        XCTAssertTrue(waitUntil { (try? self.computed("Проекты", "Часов", row: "Отпуск")) == "2" })

        // Правка часов задачи — сводка проекта пересчитана сразу (корзина и возврат — RollupRecomputeTests).
        app.terminate()
        app = launch()
        grid = app.descendants(matching: .any).matching(identifier: "database-grid").element(boundBy: 0)
        XCTAssertTrue(grid.waitForExistence(timeout: 30))
        let index = try XCTUnwrap(try rowTitles("Задачи").firstIndex(of: "Купить"))
        cell(grid, row: index, column: 1).click()
        XCTAssertTrue(element(app, "database-cell-editor").waitForExistence(timeout: 5), "Нет правки числа")
        app.typeKey("a", modifierFlags: .command)
        app.typeText("1")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitUntil { (try? self.computed("Проекты", "Часов", row: "Дом")) == "3" },
                      "После правки часов: \(String(describing: try? computed("Проекты", "Часов", row: "Дом")))")
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
        let field = element(app, "add-property-name")
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Нет поля имени нового свойства")
        app.typeText(name)
        let item = element(app, "property-type-\(type)")
        XCTAssertTrue(item.waitForExistence(timeout: 5), "Нет типа \(type)")
        item.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
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

    private func databaseId(_ database: String) throws -> String? { try query("SELECT \(Self.base)", [database]).first?.first }

    private func properties(_ database: String) throws -> [String] {
        try query("SELECT name FROM db_property WHERE databaseId = \(Self.base) AND deletedAt IS NULL ORDER BY sortKey", [database]).map { $0[0] }
    }

    private func propertyId(_ database: String, _ name: String) throws -> String? {
        try query("SELECT id FROM db_property WHERE databaseId = \(Self.base) AND name = ? AND deletedAt IS NULL", [database, name]).first?.first
    }

    private func config(_ database: String, _ name: String) throws -> String? {
        try query("SELECT config FROM db_property WHERE databaseId = \(Self.base) AND name = ? AND deletedAt IS NULL", [database, name]).first?.first
    }

    private func rowTitles(_ database: String) throws -> [String] {
        try query("SELECT title FROM page WHERE parentId = \(Self.base) AND trashedAt IS NULL ORDER BY sortKey", [database]).map { $0[0] }
    }

    /// Проекты задачи по связи «Проект» (связи хранятся у неё: её id меньше), по порядку.
    private func links(_ task: String) throws -> [String] {
        try query("""
            SELECT t.title FROM db_relation_link l JOIN page t ON t.id = l.targetRowId
            WHERE l.isPresent = 1 AND t.trashedAt IS NULL
              AND l.rowId = (SELECT id FROM page WHERE title = ? AND parentId = \(Self.base))
              AND l.propertyId = (SELECT id FROM db_property WHERE name = 'Проект' AND databaseId = \(Self.base))
            ORDER BY l.sortKey, l.id
            """, [task, "Задачи", "Задачи"]).map { $0[0] }
    }

    private func computed(_ database: String, _ property: String, row: String) throws -> String? {
        try query("""
            SELECT COALESCE(c.value, '') FROM db_computed c
            WHERE c.rowId = (SELECT id FROM page WHERE title = ? AND parentId = \(Self.base))
              AND c.propertyId = (SELECT id FROM db_property WHERE name = ? AND databaseId = \(Self.base))
            """, [row, database, property, database]).first?.first
    }
}
