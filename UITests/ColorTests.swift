import XCTest

/// Цвет текста, фона и блока вживую (FR-112): слово красится кнопкой «A» панели форматирования, другое слово получает
/// цвет фона, весь блок — цвет из меню «⋮⋮» → «Цвет». После перезапуска цвета на месте, в выгрузке в Markdown они есть.
/// Правила окна цветов и подложки проверены модульными тестами; здесь — что части работают вместе.
/// Сценарий идёт один раз в светлой теме; тёмная — снимком страницы после перезапуска в ней.
final class ColorTests: XCTestCase {
    private var library: UITestLibrary!

    override func setUpWithError() throws {
        continueAfterFailure = false
        library = try UITestLibrary.make(for: self)
    }

    @MainActor
    func testColorWordsAndBlock() throws {
        var app = library.launchApp(appearance: "light")
        app.createPage(titled: "Цвета")
        app.typeText("раз два три")

        // Слово «три» — красный текст: кнопка «A» панели, образец «Красный текст» сетки окна цветов. «Последних» ещё нет.
        app.typeKey(.leftArrow, modifierFlags: [.option, .shift])
        XCTAssertTrue(app.colorButton.waitForExistence(timeout: 5), "Панель форматирования не всплыла")
        app.colorButton.click()
        XCTAssertTrue(app.colorRow("text", "text", "red").waitForExistence(timeout: 5), "Окно цветов не открылось")
        XCTAssertFalse(app.colorRow("recent", "text", "red").exists, "«Последние» не сброшены перед тестом")
        XCTAssertEqual(app.colorRow("text", "text", "default").value as? String, "текущий", "Текущий цвет слова не отмечен")
        app.chooseColor("text", "text", "red")
        // Как у Notion 7.39: окно остаётся открытым, кольцо — у нового цвета; Esc закрывает.
        XCTAssertTrue(waitUntil { app.colorRow("text", "text", "red").value as? String == "текущий" }, "Кольцо не перешло на красный")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.colorRow("text", "text", "red").waitForNonExistence(timeout: 5), "Esc не закрыл окно цветов")

        // Слово «два » — жёлтый фон с клавиатуры по сетке: «Последние» (красный текст) → ↓ текст «По умолчанию» → ↓ «Зелёный» →
        // ↓ фон «По умолчанию» → →×4 — жёлтый фон; Enter.
        app.typeKey(.leftArrow, modifierFlags: [])
        app.typeKey(.leftArrow, modifierFlags: [.option, .shift])
        XCTAssertTrue(app.colorButton.waitForExistence(timeout: 5))
        app.colorButton.click()
        XCTAssertTrue(app.colorRow("recent", "text", "red").waitForExistence(timeout: 5), "В «Последних» нет красного текста")
        for _ in 0..<3 { app.typeKey(.downArrow, modifierFlags: []) }
        for _ in 0..<4 { app.typeKey(.rightArrow, modifierFlags: []) }
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitUntil { app.colorRow("background", "background", "yellow").value as? String == "текущий" },
                      "Кольцо не перешло на жёлтый фон")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.colorRow("background", "background", "yellow").waitForNonExistence(timeout: 5), "Esc не закрыл окно цветов")

        // Весь блок — синий текст: «⋮⋮» → «Цвет» → «Синий текст».
        app.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertTrue(app.hoverFirstBlock(), "Ручки блока не появились")
        app.blockDragHandle.click()
        XCTAssertTrue(app.popupItem("color").waitForExistence(timeout: 5), "В меню блока нет пункта «Цвет»")
        app.popupItem("color").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(app.colorRow("text", "text", "blue").waitForExistence(timeout: 5), "Окно цветов от меню блока не открылось")
        app.chooseColor("text", "text", "blue")
        XCTAssertTrue(app.colorRow("text", "text", "blue").waitForNonExistence(timeout: 5))
        attachSnapshot(of: app.pageBody, named: "colors-light")

        try exportAndCheckMarkdown(in: app)
        app.quit()

        let styles = try XCTUnwrap(library.savedTextStyles(ofPage: "Цвета").first)
        XCTAssertTrue(styles.contains("\"textColor\"") && styles.contains("\"red\""), "Красный цвет слова не записан: \(styles)")
        XCTAssertTrue(styles.contains("\"backgroundColor\"") && styles.contains("\"yellow\""), "Жёлтый фон слова не записан: \(styles)")
        let blockColor = try XCTUnwrap(library.savedBlockColors(ofPage: "Цвета").first)
        XCTAssertTrue(blockColor.contains("\"blue\""), "Синий цвет блока не записан: \(blockColor)")

        // Перезапуск в тёмной теме: цвета на месте, а текст тот же.
        app = library.launchApp(appearance: "dark")
        XCTAssertTrue(app.pageBody.waitForExistence(timeout: 10))
        XCTAssertEqual(app.pageBody.value as? String, "раз два три")
        attachSnapshot(of: app.pageBody, named: "colors-relaunched-dark")
        app.quit()
        XCTAssertEqual(try library.savedTextStyles(ofPage: "Цвета").first, styles, "После перезапуска оформление изменилось")
    }

    @MainActor
    private func exportAndCheckMarkdown(in app: XCUIApplication) throws {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyNotionColorExport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: destination) }

        app.typeKey("e", modifierFlags: [.command, .shift])
        let chooseButton = app.buttons["Выгрузить сюда"].firstMatch
        XCTAssertTrue(chooseButton.waitForExistence(timeout: 10), "Окно выбора папки не открылось по ⌘⇧E")
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeText(destination.resolvingSymlinksInPath().path)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(chooseButton.waitForExistence(timeout: 5))
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.buttons["export-show-in-finder"].waitForExistence(timeout: 30), "Выгрузка не закончилась")

        let folder = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: destination.path).first { $0.hasPrefix("MyNotion-выгрузка-") })
        let markdown = try String(contentsOf: destination.appendingPathComponent(folder).appendingPathComponent("Цвета.md"), encoding: .utf8)
        XCTAssertTrue(markdown.contains("<span data-color=\"red\">три</span>"), "Красного слова нет в выгрузке: \(markdown)")
        XCTAssertTrue(markdown.contains("<mark data-color=\"yellow\">"), "Жёлтого фона нет в выгрузке: \(markdown)")
        XCTAssertTrue(markdown.contains("mynotion:color") && markdown.contains("blue"), "Цвета блока нет в выгрузке: \(markdown)")
        app.buttons["export-close"].click()
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

    private func attachSnapshot(of element: XCUIElement, named name: String) {
        let attachment = XCTAttachment(screenshot: element.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private extension XCUIApplication {
    /// Щёлкнуть по образцу окна цветов. Образец должен быть внутри карточки (тень вокруг — 32):
    /// щелчок за её краем попал бы в прозрачную рамку тени.
    func chooseColor(_ section: String, _ target: String, _ color: String, file: StaticString = #filePath, line: UInt = #line) {
        let menu = descendants(matching: .any)["color-menu"]
        let row = colorRow(section, target, color)
        XCTAssertTrue(row.waitForExistence(timeout: 5), "В окне цветов нет строки \(section)-\(target)-\(color)", file: file, line: line)
        let visible = menu.frame.insetBy(dx: 32, dy: 32)
        XCTAssertTrue(row.frame.minY >= visible.minY && row.frame.maxY <= visible.maxY,
                      "Строка \(section)-\(target)-\(color) за краем окна цветов", file: file, line: line)
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    }

    var colorButton: XCUIElement { descendants(matching: .any)["format-color"] }

    /// Строка окна цветов: раздел (`recent`, `text`, `background`), что красят и цвет (`red`, `default`).
    func colorRow(_ section: String, _ target: String, _ color: String) -> XCUIElement {
        descendants(matching: .any)["color-\(section)-\(target)-\(color)"]
    }
}
