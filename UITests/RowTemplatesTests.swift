import SQLite3
import XCTest

/// Шаблоны строк базы вживую (T096, spec US6): «Создать ▾» без шаблонов → «+ Новый шаблон» по центру с янтарной полосой,
/// название, тело и «Сегодня» из «Быстрого выбора» даты; шаблон не строка таблицы; «Сделать по умолчанию» → «Создать»
/// делает строку по нему с сегодняшней датой; «Пустая страница» — пустую; «Дублировать» и «Удалить».
/// Правила копии на уровне данных — `RowTemplateInstantiationTests`.
final class RowTemplatesTests: XCTestCase {
    private var library: UITestLibrary!
    static let header: CGFloat = 33, titleWidth: CGFloat = 280

    override func setUpWithError() throws {
        continueAfterFailure = false
        library = try UITestLibrary.make(for: self)
    }

    @MainActor
    func testRowTemplatesFromNewMenu() throws {
        let app = library.launchApp()
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
        addDateColumn(app, grid: grid)
        let rowsBefore = try liveRows().count

        // «Создать ▾» без шаблонов: подсказка и «+ Новый шаблон».
        openNewMenu(app)
        XCTAssertFalse(element(app, "row-template-empty").exists, "Без шаблонов в меню «Пустая страница»")
        press(element(app, "row-template-new"))
        XCTAssertTrue(element(app, "row-center-peek").waitForExistence(timeout: 5), "Новый шаблон открылся не по центру")
        XCTAssertTrue(element(app, "row-template-banner").waitForExistence(timeout: 5), "Нет янтарной полосы «Вы правите шаблон»")
        app.typeText("Созвон")
        app.typeKey(.return, modifierFlags: [])
        app.typeText("Повестка")

        // «Быстрый выбор» окна даты шаблона: «Сегодня».
        let date = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'row-property' AND label == 'Срок'")).element
        XCTAssertTrue(date.waitForExistence(timeout: 5), "На странице шаблона нет свойства «Срок»")
        date.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)).click()
        let today = element(app, "date-shortcut-today")
        XCTAssertTrue(today.waitForExistence(timeout: 5), "В окне даты шаблона нет «Быстрого выбора»")
        press(today)
        XCTAssertTrue(waitUntil { (try? self.templates())?.first.map { $0.date.contains("\"relative\":\"today\"") } == true },
                      "У шаблона не «Сегодня»: \(String(describing: try? templates()))")
        app.typeKey(.escape, modifierFlags: [])
        element(app, "row-peek-close").click()
        XCTAssertTrue(waitUntil { (try? self.templates())?.map(\.title) == ["Созвон"] }, "Шаблон: \(String(describing: try? templates()))")
        XCTAssertEqual(try liveRows().count, rowsBefore, "Шаблон стал строкой таблицы")

        // «•••» → «Сделать по умолчанию»; «Создать» — строка по шаблону с сегодняшней датой и телом.
        openNewMenu(app)
        let template = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'row-template-' AND label BEGINSWITH 'Созвон'")).element
        XCTAssertTrue(template.waitForExistence(timeout: 5), "В «Создать ▾» нет шаблона «Созвон»")
        XCTAssertTrue(element(app, "row-template-empty").exists, "В меню нет «Пустой страницы»")
        press(app.descendants(matching: .any)["\(template.identifier)-more"])
        let setDefault = element(app, "row-template-set-default")
        XCTAssertTrue(setDefault.waitForExistence(timeout: 5), "В меню шаблона нет «Сделать по умолчанию»")
        press(setDefault)
        XCTAssertTrue(waitUntil { (try? self.defaultTemplateTitle()) == "Созвон" }, "Шаблон не стал шаблоном по умолчанию")

        element(app, "database-new-row").click()
        XCTAssertTrue(waitUntil { (try? self.liveRows())?.count == rowsBefore + 1 }, "«Создать» не сделал строку")
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let day = String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
        XCTAssertTrue(waitUntil { (try? self.rowsByTemplate()).map { $0.contains { $0.date.contains(day) && !$0.date.contains("relative") } } == true },
                      "У строки по шаблону не сегодняшняя дата: \(String(describing: try? rowsByTemplate()))")
        XCTAssertTrue(waitUntil { (try? self.bodyTexts(ofRowTitled: "Созвон"))?.contains("Повестка") == true }, "В строке нет тела шаблона")
        closePeek(app)

        // «Пустая страница» — строка без значений шаблона.
        let emptyBefore = try pages(isTemplate: false).filter { $0.title.isEmpty && $0.date.isEmpty }.count
        openNewMenu(app)
        press(element(app, "row-template-empty"))
        XCTAssertTrue(waitUntil { (try? self.liveRows())?.count == rowsBefore + 2 }, "«Пустая страница» не сделала строку")
        let rowsAfter = try pages(isTemplate: false)
        XCTAssertEqual(rowsAfter.filter { $0.title.isEmpty && $0.date.isEmpty }.count, emptyBefore + 1, "Строка «Пустой страницы» не пустая: \(rowsAfter)")
        closePeek(app)

        // «Дублировать» — копия открывается по центру; «Удалить» копию — снова один шаблон.
        openNewMenu(app)
        press(app.descendants(matching: .any)["\(template.identifier)-more"])
        press(element(app, "row-template-duplicate"))
        XCTAssertTrue(element(app, "row-template-banner").waitForExistence(timeout: 5), "Копия шаблона не открылась")
        XCTAssertTrue(waitUntil { (try? self.templates())?.count == 2 }, "Копии шаблона нет: \(String(describing: try? templates()))")
        element(app, "row-peek-close").click()
        openNewMenu(app)
        // Копия встаёт сразу под исходным: вторая «•••» среди шаблонов (без «Пустой страницы»).
        let mores = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'row-template-' AND identifier ENDSWITH '-more' AND identifier != 'row-template-empty-more'"))
        XCTAssertEqual(mores.count, 2, "В меню не два шаблона")
        press(mores.element(boundBy: 1))
        press(element(app, "row-template-delete"))
        XCTAssertTrue(waitUntil { (try? self.templates())?.count == 1 }, "Копия не удалилась: \(String(describing: try? templates()))")
        app.quit()
    }

    // MARK: Помощники

    @MainActor
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement { app.descendants(matching: .any)[identifier] }

    /// Строки меню — пункты меню (menuItem): обычный `click()` ждёт системного меню, поэтому щелчок по точке.
    @MainActor
    private func press(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 5), "Нет \(element)")
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    }

    /// Новая строка открывается сбоку с курсором в названии: Esc лишь снимает курсор, поэтому «»».
    @MainActor
    private func closePeek(_ app: XCUIApplication) {
        let close = element(app, "row-peek-close")
        XCTAssertTrue(close.waitForExistence(timeout: 5), "Строка не открылась в просмотре")
        close.click()
        XCTAssertTrue(waitUntil { !close.exists }, "Просмотр строки не закрылся")
    }

    @MainActor
    private func openNewMenu(_ app: XCUIApplication) {
        let chevron = element(app, "database-new-row-templates")
        XCTAssertTrue(chevron.waitForExistence(timeout: 5), "У «Создать» нет «▾»")
        chevron.click()
        XCTAssertTrue(element(app, "database-new-row-menu").waitForExistence(timeout: 5), "Меню «Создать ▾» не открылось")
    }

    @MainActor
    private func addDateColumn(_ app: XCUIApplication, grid: XCUIElement) {
        grid.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: Self.titleWidth + 16, dy: Self.header / 2)).click()
        XCTAssertTrue(element(app, "add-property-name").waitForExistence(timeout: 5), "Нет поля имени нового свойства")
        app.typeText("Срок")
        let item = element(app, "property-type-date")
        XCTAssertTrue(item.waitForExistence(timeout: 5), "Нет типа «Дата»")
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

    private static let base = "(SELECT id FROM page WHERE title = 'Задачи' AND trashedAt IS NULL AND id IN (SELECT pageId FROM db_database))"
    private static let dateProperty = "(SELECT id FROM db_property WHERE name = 'Срок' AND databaseId = \(base))"

    private struct Page: CustomStringConvertible {
        var id: String, title: String, date: String
        var description: String { "\(title): \(date)" }
    }

    /// Названия строк таблицы (не шаблонов).
    private func liveRows() throws -> [String] {
        try query("SELECT title FROM page WHERE parentId = \(Self.base) AND trashedAt IS NULL AND isTemplate = 0").map { $0[0] }
    }

    private func pages(isTemplate: Bool) throws -> [Page] {
        try query("""
            SELECT p.id, p.title, coalesce(c.value, '') FROM page p
            LEFT JOIN db_cell c ON c.rowId = p.id AND c.propertyId = \(Self.dateProperty)
            WHERE p.parentId = \(Self.base) AND p.trashedAt IS NULL AND p.isTemplate = \(isTemplate ? 1 : 0) ORDER BY p.sortKey
            """).map { Page(id: $0[0], title: $0[1], date: $0[2]) }
    }

    private func templates() throws -> [Page] { try pages(isTemplate: true) }
    private func rowsByTemplate() throws -> [Page] { try pages(isTemplate: false).filter { $0.title == "Созвон" } }

    private func defaultTemplateTitle() throws -> String? {
        try query("SELECT title FROM page WHERE id = (SELECT defaultTemplateId FROM db_database WHERE pageId = \(Self.base))").first?.first
    }

    private func bodyTexts(ofRowTitled title: String) throws -> [String] {
        try query("""
            SELECT b.text FROM block b JOIN page p ON p.id = b.pageId
            WHERE p.parentId = \(Self.base) AND p.isTemplate = 0 AND p.trashedAt IS NULL AND p.title = '\(title)' AND b.isDeleted = 0
            """).map { $0[0] }
    }

    private func query(_ sql: String) throws -> [[String]] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(library.databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw Failure.open }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw Failure.sql(String(cString: sqlite3_errmsg(database))) }
        defer { sqlite3_finalize(statement) }
        var rows: [[String]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append((0..<sqlite3_column_count(statement)).map { sqlite3_column_text(statement, $0).map { String(cString: $0) } ?? "" })
        }
        return rows
    }

    private enum Failure: Error { case open, sql(String) }
}
