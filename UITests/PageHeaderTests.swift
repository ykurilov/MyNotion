import AppKit
import SQLite3
import XCTest

/// Шапка страницы с обложкой и вид страницы (US1, quickstart.md): «Добавить обложку» под мышью ставит обложку
/// из галереи; «Сменить обложку» → «Загрузить» — своя картинка; «Переместить» → «Сохранить положение»; «Убрать» и ⌘Z;
/// «•••» → «Вид страницы» — оба переключателя; после перезапуска всё на месте.
final class PageHeaderTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCoverAndAppearanceSurviveRelaunch() throws {
        let library = try UITestLibrary.make(for: self)
        let picture = library.databaseURL.deletingLastPathComponent().appendingPathComponent("cover-sunset.png")
        try Self.png(width: 1200, height: 900).write(to: picture)
        var app = library.launchApp()
        app.createPage(titled: "Обложка")

        // Без обложки «Добавить обложку» — под мышью над шапкой; щелчок — обложка из галереи.
        let addCover = app.descendants(matching: .any)["add-page-cover"]
        app.pageTitle.hover()
        XCTAssertTrue(addCover.waitForExistence(timeout: 5), "«Добавить обложку» не появилась при наведении")
        addCover.click()
        let cover = app.descendants(matching: .any)["page-cover"]
        XCTAssertTrue(cover.waitForExistence(timeout: 5), "Обложка не поставилась")
        XCTAssertTrue(Self.galleryIds.contains(cover.value as? String ?? ""), "Не из галереи: \(String(describing: cover.value))")

        // «Сменить обложку» → «Загрузить» → картинка из папки теста.
        cover.hover()
        let change = app.descendants(matching: .any)["change-page-cover"]
        XCTAssertTrue(change.waitForExistence(timeout: 5), "«Сменить обложку» не появилась")
        change.click()
        let uploadTab = app.descendants(matching: .any)["cover-tab-upload"]
        XCTAssertTrue(uploadTab.waitForExistence(timeout: 5), "Окно «Сменить обложку» не открылось")
        XCTAssertTrue(app.descendants(matching: .any)["cover-gallery-gradients_3"].exists, "В галерее нет плиток")
        uploadTab.click()
        app.descendants(matching: .any)["cover-upload-file"].click()
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "Окно выбора файла не открылось")
        // Путь — в поле «Перейти к папке» (⇧⌘G), затем кнопка окна «Загрузить».
        app.typeKey("g", modifierFlags: [.command, .shift])
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        app.typeText(picture.path)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        app.typeKey(.return, modifierFlags: [])
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        let upload = sheet.buttons["Загрузить"]
        if upload.waitForExistence(timeout: 3), upload.isEnabled { upload.click() } else { app.typeKey(.return, modifierFlags: []) }
        if !waitForAbsence(sheet) {
            add(XCTAttachment(screenshot: app.screenshot()))
            XCTFail("Окно выбора файла не закрылось: \(sheet.debugDescription)")
        }
        XCTAssertTrue(waitFor(cover, value: "cover-sunset.png"), "Своя картинка не стала обложкой: \(String(describing: cover.value))")

        // «Переместить»: тянем картинку вниз, «Сохранить положение».
        cover.hover()
        app.descendants(matching: .any)["reposition-page-cover"].click()
        let save = app.descendants(matching: .any)["save-cover-position"]
        XCTAssertTrue(save.waitForExistence(timeout: 5), "Режим «Переместить» не включился")
        cover.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.3))
            .click(forDuration: 0.2, thenDragTo: cover.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.7)))
        save.click()
        XCTAssertTrue(waitForAbsence(save), "«Сохранить положение» не закрыла режим")

        // «Убрать» и ⌘Z — обложка вернулась.
        cover.hover()
        change.click()
        let remove = app.descendants(matching: .any)["cover-remove"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.click()
        XCTAssertTrue(waitForAbsence(cover), "Обложка не убралась")
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(cover.waitForExistence(timeout: 5), "⌘Z не вернул обложку")
        XCTAssertTrue(waitFor(cover, value: "cover-sunset.png"))

        // «•••» → «Вид страницы ›» → «Мелкий шрифт» и «Широкая страница».
        setAppearance(app, ["page-appearance-small-text", "page-appearance-full-width"], expected: "1")

        app.quit()
        let saved = try savedAppearance(library, page: "Обложка")
        XCTAssertTrue(saved.cover.contains("\"file\""), "В базе не картинка: \(saved.cover)")
        XCTAssertFalse(saved.cover.contains("\"offset\":0.5"), "Сдвиг не сохранился: \(saved.cover)")
        XCTAssertTrue(saved.isSmallText && saved.isFullWidth, "Вид страницы не сохранился")

        // Перезапуск: обложка и вид на месте; ⌘Z выключает широкую.
        app = library.launchApp()
        XCTAssertTrue(cover.waitForExistence(timeout: 10), "После перезапуска нет обложки")
        XCTAssertTrue(waitFor(cover, value: "cover-sunset.png"))
        openAppearance(app)
        XCTAssertEqual(app.descendants(matching: .any)["page-appearance-small-text"].value as? Int, 1)
        XCTAssertEqual(app.descendants(matching: .any)["page-appearance-full-width"].value as? Int, 1)
        app.descendants(matching: .any)["page-appearance-full-width"].click()
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey(.escape, modifierFlags: [])
        app.pageBody.click()
        app.typeKey("z", modifierFlags: .command)
        app.quit()
        XCTAssertTrue(try savedAppearance(library, page: "Обложка").isFullWidth, "⌘Z не вернул широкую страницу")
    }

    static let galleryIds: Set<String> = ["solid_red", "solid_yellow", "solid_blue", "solid_beige", "gradients_8", "gradients_2",
                                          "gradients_11", "gradients_4", "gradients_10", "gradients_5", "gradients_3"]

    @MainActor
    private func openAppearance(_ app: XCUIApplication) {
        let menu = app.descendants(matching: .any)["page-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.click()
        let appearance = app.descendants(matching: .any)["page-menu-appearance"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 5), "В меню нет «Вид страницы»")
        // Пункт меню XCUITest ищет в системном меню и ждёт его открытия: щелчок — по точке, а не по элементу.
        appearance.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(app.descendants(matching: .any)["page-appearance-small-text"].waitForExistence(timeout: 5), "Подменю не открылось")
    }

    @MainActor
    private func setAppearance(_ app: XCUIApplication, _ identifiers: [String], expected: String) {
        openAppearance(app)
        for identifier in identifiers {
            let toggle = app.descendants(matching: .any)[identifier]
            toggle.click()
            XCTAssertEqual(String(describing: toggle.value ?? ""), expected, "\(identifier) не переключился")
        }
        app.typeKey(.escape, modifierFlags: [])
    }

    private struct SavedAppearance {
        var cover: String
        var isFullWidth: Bool
        var isSmallText: Bool
    }

    private func savedAppearance(_ library: UITestLibrary, page title: String) throws -> SavedAppearance {
        var database: OpaquePointer?
        guard sqlite3_open_v2(library.databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw NSError(domain: "SQLite", code: 1)
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        let sql = "SELECT COALESCE(cover, ''), isFullWidth, isSmallText FROM page WHERE title = ? AND trashedAt IS NULL"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw NSError(domain: "SQLite", code: 2) }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, title, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_ROW else { throw NSError(domain: "SQLite", code: 3) }
        return SavedAppearance(cover: String(cString: sqlite3_column_text(statement, 0)), isFullWidth: sqlite3_column_int(statement, 1) != 0,
                               isSmallText: sqlite3_column_int(statement, 2) != 0)
    }

    private static func png(width: Int, height: Int) throws -> Data {
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            NSGradient(colors: [.systemOrange, .systemBlue])?.draw(in: rect, angle: 90)
            return true
        }
        guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "PNG", code: 1)
        }
        return png
    }

    @MainActor
    private func waitFor(_ element: XCUIElement, value: String) -> Bool {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if element.exists, element.value as? String == value { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return false
    }

    @MainActor
    private func waitForAbsence(_ element: XCUIElement) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if !element.exists { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return false
    }
}
