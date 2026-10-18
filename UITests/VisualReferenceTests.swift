import XCTest

/// Сверка с образцом Notion (FR-031, SC-012): страница «MyNotion — образец» в окне 1440×900 в обеих темах.
/// Снимки окна — `mynotion-<тема>-page.png` во временной папке исполнителя (путь в журнале, «Снимок образца:»)
/// и во вложениях; их кладут рядом со снимками Notion в `specs/001-core-pages-editor/visual-reference/`.
/// По рамкам элементов — цифры contracts/visual-style.md с допуском 1 pt. Точная геометрия блоков — в модульных
/// тестах (`EditorChromeGeometryTests`, `PageColumnPositionTests`, `SidebarGeometryTests`); здесь — собранное окно.
final class VisualReferenceTests: XCTestCase {
    static let windowSize = CGSize(width: 1440, height: 900)
    static let tolerance: CGFloat = 1
    private var library: UITestLibrary!

    override func setUpWithError() throws {
        continueAfterFailure = true
        library = try UITestLibrary.make(for: self)
    }

    @MainActor func testLightThemeMatchesVisualStyle() throws { try checkSamplePage(appearance: "light") }
    @MainActor func testDarkThemeMatchesVisualStyle() throws { try checkSamplePage(appearance: "dark") }

    @MainActor
    private func checkSamplePage(appearance: String) throws {
        let app = XCUIApplication()
        app.launchArguments = ["--database", library.databaseURL.path, "--generate-visual-sample", "--appearance", appearance]
        app.launch()
        defer { app.terminate() }
        let window = app.windows.firstMatch
        let title = app.textFields["page-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertEqual(title.value as? String, "MyNotion — образец")
        try resize(window, to: Self.windowSize)

        // Колонка текста 720 по центру области страницы вместе с полосой прокрутки. Поле названия занимает колонку
        // целиком, а XCUITest отдаёт рамку его ячейки (`page-title` стоит и на ячейке) — на 1 pt внутри с каждой стороны.
        let page = app.scrollViews.containing(.textView, identifier: "page-body").firstMatch
        XCTAssertTrue(page.exists)
        let column = title.frame.insetBy(dx: -1, dy: 0)
        XCTAssertEqual(column.width, 720, accuracy: Self.tolerance, "Ширина колонки")
        XCTAssertEqual(column.midX, page.frame.midX, accuracy: Self.tolerance, "Колонка не по центру: \(column) в \(page.frame)")

        // Строки дерева: подсветка 30, шаг 31.
        let rows = app.outlines["page-tree"].outlineRows
        XCTAssertGreaterThanOrEqual(rows.count, 2)
        let first = rows.element(boundBy: 0).frame, second = rows.element(boundBy: 1).frame
        XCTAssertEqual(second.minY - first.minY, 31, accuracy: Self.tolerance, "Шаг строк дерева")

        // Ручки блока под мышью: «+» 24×24 на 52 левее колонки, «⋮⋮» 18×24 на 28 левее.
        let body = app.textViews["page-body"]
        body.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: title.frame.minX - body.frame.minX + 40, dy: title.frame.maxY - body.frame.minY + 60))
            .hover()
        let addHandle = app.descendants(matching: .any).matching(identifier: "block-handle-add").firstMatch
        let dragHandle = app.descendants(matching: .any).matching(identifier: "block-handle-drag").firstMatch
        if addHandle.waitForExistence(timeout: 3), dragHandle.exists {
            XCTAssertEqual(addHandle.frame.size.width, 24, accuracy: Self.tolerance)
            XCTAssertEqual(addHandle.frame.size.height, 24, accuracy: Self.tolerance)
            XCTAssertEqual(column.minX - addHandle.frame.minX, 52, accuracy: Self.tolerance, "«+» от колонки")
            XCTAssertEqual(dragHandle.frame.size.width, 18, accuracy: Self.tolerance)
            XCTAssertEqual(column.minX - dragHandle.frame.minX, 28, accuracy: Self.tolerance, "«⋮⋮» от колонки")
        } else {
            XCTFail("Ручки блока не появились под мышью")
        }

        // Снимок окна для пары «Notion / MyNotion»: мышь уводим с текста, чтобы ручек не было.
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.99)).hover()
        let screenshot = window.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "mynotion-\(appearance)-page"
        attachment.lifetime = .keepAlways
        add(attachment)
        // Исполнитель UI-тестов в «песочнице»: пишет только в свою временную папку.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mynotion-visual-reference", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("mynotion-\(appearance)-page.png")
        try screenshot.pngRepresentation.write(to: file)
        print("Снимок образца: \(file.path)")
    }

    /// Окно 1440×900: левый верхний угол тянется к углу экрана под строкой меню, затем правый нижний — до размера.
    @MainActor
    private func resize(_ window: XCUIElement, to size: CGSize) throws {
        let frame = window.frame
        let topLeft = window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 1, dy: 1))
        topLeft.press(forDuration: 0.2, thenDragTo: topLeft.withOffset(CGVector(dx: -frame.minX, dy: 40 - frame.minY)))
        // Окно помнит размер прошлого запуска, а перетаскивание не всегда доходит до места: тянуть, пока не совпадёт.
        for _ in 0..<3 {
            let moved = window.frame
            guard abs(moved.width - size.width) > Self.tolerance || abs(moved.height - size.height) > Self.tolerance else { break }
            let corner = window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: moved.width - 1, dy: moved.height - 1))
            corner.press(forDuration: 0.2, thenDragTo: corner.withOffset(CGVector(dx: size.width - moved.width, dy: size.height - moved.height)))
        }
        XCTAssertEqual(window.frame.width, size.width, accuracy: Self.tolerance, "Ширина окна")
        XCTAssertEqual(window.frame.height, size.height, accuracy: Self.tolerance, "Высота окна")
    }
}
