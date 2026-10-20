import SQLite3
import XCTest

/// Таблицы и колонки вживую (US6, Independent Test): «/» → таблица, Tab по ячейкам и новая строка, строка заголовков,
/// «+» строка и столбец; перетаскивание «⋮⋮» к правому краю блока — две колонки; ⌘F находит слово в колонке;
/// после перезапуска всё на месте. Логика каждого шага — в модульных тестах PageEditorTests; здесь — что части работают вместе.
final class TablesAndColumnsTests: XCTestCase {
    private var library: UITestLibrary!

    override func setUpWithError() throws {
        continueAfterFailure = false
        library = try UITestLibrary.make(for: self)
    }

    @MainActor
    func testTableColumnsFindAndRelaunch() throws {
        var app = library.launchApp()
        app.createPage(titled: "Таблицы и колонки")
        app.typeText("/табл")
        XCTAssertTrue(app.popupItem("table").waitForExistence(timeout: 5), "Меню «/» не нашло таблицу")
        app.typeKey(.return, modifierFlags: [])
        let cell = app.textViews["table-cell"]
        XCTAssertTrue(cell.waitForExistence(timeout: 5), "Нет поля правки ячейки")

        // 2 столбца × 3 строки, как у Notion 7.39 → Tab в последней ячейке добавляет четвёртую строку.
        for (index, text) in ["Имя", "Роль", "Юрий", "Автор", "Мишка", "Тестер", "Оля"].enumerated() {
            if index > 0 { app.typeKey(.tab, modifierFlags: []) }
            app.typeText(text)
        }
        let table = app.descendants(matching: .any)["table"]
        XCTAssertTrue(table.exists)
        // Esc, как у Notion 7.39: ячейка → строка (синяя рамка вокруг строки) → таблица как блок.
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey(.escape, modifierFlags: [])
        let rowSelected = XCTAttachment(screenshot: table.screenshot())
        rowSelected.name = "table-row-selected"
        rowSelected.lifetime = .keepAlways
        add(rowSelected)
        app.typeKey(.escape, modifierFlags: [])
        table.rightClick()
        let headerRow = app.menuItems["Строка заголовков"]
        XCTAssertTrue(headerRow.waitForExistence(timeout: 5), "Нет меню строки и столбца")
        headerRow.click()
        table.hover()
        let addColumn = app.descendants(matching: .any)["table-add-column"]
        XCTAssertTrue(addColumn.waitForExistence(timeout: 5))
        addColumn.click()
        app.descendants(matching: .any)["table-add-row"].click()

        // Под таблицей — пустой абзац: два блока для колонок.
        // Щелчок в первую ячейку (после Esc поля правки нет), вниз через 5 строк — в абзац под таблицей.
        table.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 20, dy: 15)).click()
        XCTAssertTrue(app.textViews["table-cell"].waitForExistence(timeout: 5), "Щелчок в ячейку не открыл поле правки")
        for _ in 0..<6 { app.typeKey(.downArrow, modifierFlags: []) }
        app.typeText("Левый")
        app.typeKey(.return, modifierFlags: [])
        app.typeText("Правый")

        // «⋮⋮» блока «Правый» — к правому краю блока «Левый».
        let body = app.pageBody
        let lineHeight: CGFloat = 30
        let leftY = table.frame.maxY + lineHeight / 2 + 6
        let rightY = leftY + lineHeight
        let columnLeft = body.frame.minX + (body.frame.width - 720) / 2
        let origin = body.coordinate(withNormalizedOffset: .zero)
        func point(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
            origin.withOffset(CGVector(dx: x - body.frame.minX, dy: y - body.frame.minY))
        }
        point(columnLeft + 40, rightY).hover()
        let handle = app.blockDragHandle
        XCTAssertTrue(handle.waitForExistence(timeout: 5), "Нет ручки «⋮⋮» у блока «Правый»")
        handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.3, thenDragTo: point(columnLeft + 720 - 12, leftY))
        let columns = app.textViews.matching(identifier: "flow-body")
        XCTAssertTrue(waitUntil { columns.count == 2 }, "Колонки не собрались")

        // ⌘F находит слово в колонке: фокус — в редакторе правой колонки.
        app.typeKey("f", modifierFlags: .command)
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5), "⌘F не открыл полосу поиска")
        app.typeText("Правый")
        app.typeKey(.return, modifierFlags: [])
        let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasKeyboardFocus == true")).allElementsBoundByIndex
            .map { "\($0.elementType.rawValue):\($0.identifier)" }
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil { columns.allElementsBoundByIndex.contains { ($0.value(forKey: "hasKeyboardFocus") as? Bool) == true } },
                      "После ⌘F и Esc курсор не в колонке; фокус был: \(focused)")
        app.quit()

        let saved = try savedTree(ofPage: "Таблицы и колонки")
        XCTAssertTrue(saved.contains("table header-row"), "\(saved)")
        XCTAssertEqual(saved.filter { $0 == "tableColumn" }.count, 3, "\(saved)")
        XCTAssertEqual(saved.filter { $0 == "tableRow" }.count, 5, "\(saved)")
        for text in ["Имя", "Роль", "Юрий", "Автор", "Мишка", "Тестер", "Оля"] {
            XCTAssertTrue(saved.contains("tableCell \(text)"), "нет ячейки «\(text)»: \(saved)")
        }
        XCTAssertTrue(saved.contains("columnList") && saved.filter { $0 == "column" }.count == 2, "\(saved)")
        XCTAssertTrue(saved.contains("in-column paragraph Левый") && saved.contains("in-column paragraph Правый"), "\(saved)")

        // Перезапуск: таблица и колонки на месте.
        app = library.launchApp()
        XCTAssertTrue(app.pageBody.waitForExistence(timeout: 10))
        app.staticTexts["Таблицы и колонки"].firstMatch.click()
        XCTAssertTrue(app.descendants(matching: .any)["table"].waitForExistence(timeout: 10), "Таблица не показалась после перезапуска")
        XCTAssertTrue(waitUntil { app.textViews.matching(identifier: "flow-body").count == 2 }, "Колонки не показались после перезапуска")
        app.quit()
    }

    /// Блоки страницы с местом: «table header-row», «tableCell Текст», «in-column paragraph Текст», «column»…
    private func savedTree(ofPage title: String) throws -> [String] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(library.databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw UITestLibrary.SQLiteFailure(message: "база не открылась")
        }
        defer { sqlite3_close(database) }
        let sql = """
            SELECT block.kind, block.text, block.props, COALESCE(container.kind, '') FROM block
            JOIN page ON page.id = block.pageId
            LEFT JOIN block AS container ON container.id = block.containerId
            WHERE page.title = ? AND page.trashedAt IS NULL AND block.isDeleted = 0
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw UITestLibrary.SQLiteFailure(message: String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, title, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        var rows: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let kind = String(cString: sqlite3_column_text(statement, 0))
            let text = String(cString: sqlite3_column_text(statement, 1))
            let props = String(cString: sqlite3_column_text(statement, 2))
            let container = String(cString: sqlite3_column_text(statement, 3))
            switch kind {
            case "table": rows.append(props.contains("\"hasHeaderRow\":true") ? "table header-row" : "table")
            case "tableCell": rows.append("tableCell \(text)")
            default:
                rows.append(container == "column" ? "in-column \(kind) \(text)" : (text.isEmpty ? kind : "\(kind) \(text)"))
            }
        }
        return rows
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
