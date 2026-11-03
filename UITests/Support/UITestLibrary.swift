import Foundation
import SQLite3
import XCTest

/// Своя временная база для UI-сценария и чтение того, что приложение записало на диск.
/// Маркеры, номера и квадраты чекбоксов рисуются, а не лежат в тексте, поэтому тип блока проверяется по базе.
struct UITestLibrary {
    let databaseURL: URL

    struct SavedBlock: Equatable, CustomStringConvertible {
        var kind: String
        var text: String
        var indent = 0
        var isChecked = false

        var description: String { "\(kind)(\(text), indent: \(indent), checked: \(isChecked))" }
    }

    /// Папка удаляется после теста.
    static func make(for testCase: XCTestCase) throws -> UITestLibrary {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MyNotionUITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        testCase.addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return UITestLibrary(databaseURL: folder.appendingPathComponent("MyNotion.sqlite"))
    }

    /// Место и размер окна при запуске: 1200 × 800, как `defaultSize` приложения.
    static let startWindowFrame = "156 76 1200 800 0 0 1512 952 "

    @MainActor
    /// `keepsTextZoom` — масштаб текста из прошлого запуска; иначе — обычный 100 %, что бы ни оставил другой тест.
    func launchApp(appearance: String? = nil, arguments extra: [String] = [], keepsTextZoom: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        // «-MyNotion.recentColors ""» перекрывает сохранённые «Последние цвета» пустым значением: у каждого запуска свои, чистые.
        // Окно — с одного места и размера, как у нового запуска: иначе тест начинает в окне, которое оставил прошлый запуск
        // (галерея в окне 900×700 — и колонке страницы не хватает ширины).
        app.launchArguments = ["--database", databaseURL.path, "-MyNotion.recentColors", "",
                               "-NSWindow Frame pages-AppWindow-1", Self.startWindowFrame]
            + (keepsTextZoom ? [] : ["-MyNotion.pageTextZoom", "1"])
            + (appearance.map { ["--appearance", $0] } ?? []) + extra
        app.launch()
        return app
    }

    /// Блоки страницы с названием `title` в порядке страницы. Читать после выхода приложения.
    func savedBlocks(ofPage title: String) throws -> [SavedBlock] {
        try rows(ofPage: title, columns: "block.kind, block.text, block.indent, block.isChecked") { statement in
            SavedBlock(
                kind: String(cString: sqlite3_column_text(statement, 0)),
                text: String(cString: sqlite3_column_text(statement, 1)),
                indent: Int(sqlite3_column_int(statement, 2)),
                isChecked: sqlite3_column_int(statement, 3) != 0
            )
        }
    }

    /// Оформление блоков страницы — записи отрезков в том виде, как они лежат в базе (JSON). Читать после выхода.
    func savedTextStyles(ofPage title: String) throws -> [String] {
        try rows(ofPage: title, columns: "block.textStyles") { String(cString: sqlite3_column_text($0, 0)) }
    }

    /// Цвет блоков страницы в том виде, как лежит в базе (JSON, например `{"text":"blue"}`). Читать после выхода.
    func savedBlockColors(ofPage title: String) throws -> [String] {
        try rows(ofPage: title, columns: "COALESCE(block.color, '')") { String(cString: sqlite3_column_text($0, 0)) }
    }

    /// Иконка страницы в базе; `nil` — без иконки. Читать после выхода.
    func savedIcon(ofPage title: String) throws -> String? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw SQLiteFailure(message: "база не открылась: \(databaseURL.path)")
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT icon FROM page WHERE title = ? AND trashedAt IS NULL", -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteFailure(message: String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, title, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_ROW else { throw SQLiteFailure(message: "нет страницы «\(title)»") }
        return sqlite3_column_text(statement, 0).map { String(cString: $0) }
    }

    private func rows<Row>(ofPage title: String, columns: String, row: (OpaquePointer?) -> Row) throws -> [Row] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw SQLiteFailure(message: "база не открылась: \(databaseURL.path)")
        }
        defer { sqlite3_close(database) }
        let sql = """
            SELECT \(columns) FROM block
            JOIN page ON page.id = block.pageId
            WHERE page.title = ? AND page.trashedAt IS NULL AND block.isDeleted = 0
            ORDER BY block.sortKey
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteFailure(message: String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, title, -1, transient)
        var rows: [Row] = []
        while sqlite3_step(statement) == SQLITE_ROW { rows.append(row(statement)) }
        return rows
    }

    struct SQLiteFailure: Error, CustomStringConvertible {
        let message: String
        var description: String { "SQLite: \(message)" }
    }
}

extension XCUIApplication {
    var pageTitle: XCUIElement { textFields["page-title"] }
    var pageBody: XCUIElement { textViews["page-body"] }
    var blockDragHandle: XCUIElement { descendants(matching: .any)["block-handle-drag"] }
    var blockAddHandle: XCUIElement { descendants(matching: .any)["block-handle-add"] }
    var blockFoldHandle: XCUIElement { descendants(matching: .any)["block-handle-fold"] }

    func popupItem(_ identifier: String) -> XCUIElement {
        descendants(matching: .menuItem)["popup-item-\(identifier)"]
    }

    /// Пункт меню строки панели (карточка, как у Notion): `slot` — место пункта (`favorite`, `trash`, `moveTo`…).
    func rowMenuItem(_ slot: String) -> XCUIElement {
        descendants(matching: .menuItem)["row-menu-\(slot)"]
    }

    /// Выбрать пункт меню строки: карточка — отдельное окно поверх, щелчок по точке пункта.
    func chooseRowMenuItem(_ slot: String, file: StaticString = #filePath, line: UInt = #line) {
        let item = rowMenuItem(slot)
        XCTAssertTrue(item.waitForExistence(timeout: 5), "В меню строки нет пункта \(slot)", file: file, line: line)
        item.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    }

    /// Новая страница по ⌘N с названием; курсор переходит в текст страницы.
    func createPage(titled title: String) {
        typeKey("n", modifierFlags: .command)
        XCTAssertTrue(pageTitle.waitForExistence(timeout: 10))
        typeText(title)
        typeKey(.return, modifierFlags: [])
    }

    func quit() {
        typeKey("q", modifierFlags: .command)
        XCTAssertTrue(wait(for: .notRunning, timeout: 10), "Приложение не вышло по ⌘Q")
    }

    /// Навести мышь на первый блок под названием и дождаться ручек «+ ⋮⋮».
    /// Ведём мышь вниз от названия, пока ручки не появятся: первая найденная строка — первый блок.
    func hoverFirstBlock() -> Bool {
        let titleFrame = pageTitle.frame
        let body = pageBody
        let origin = body.coordinate(withNormalizedOffset: .zero)
        for step in 0..<20 {
            let point = CGPoint(x: titleFrame.minX + 40, y: titleFrame.maxY + 4 + CGFloat(step) * 4)
            origin.withOffset(CGVector(dx: point.x - body.frame.minX, dy: point.y - body.frame.minY)).hover()
            if blockDragHandle.waitForExistence(timeout: 0.3), blockDragHandle.isHittable { return true }
        }
        return false
    }
}
