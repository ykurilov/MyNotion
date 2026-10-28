import AppKit
import XCTest

/// Сверка с образцом Notion (FR-031, SC-012): страница «MyNotion — образец» в окне 1440×900 в обеих темах.
/// Светлая и тёмная тема (FR-028): окно, дерево и редактор снимаются в обеих темах (вложения прогона);
/// по снимкам проверяется, что фон дерева и редактора светлый в светлой теме и тёмный в тёмной.
/// Геометрия от темы не зависит и проверяется один раз, в светлой; тёмная — только снимки.
/// Полосы («Изменения не сохранены», синхронизация, импорт) и окно «Две версии» в обеих темах снимает
/// галерея состояний (`scripts/vm/run-in-vm.sh gallery`).
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

    @MainActor func testLightThemeMatchesVisualStyle() throws { try checkSamplePage(appearance: "light", measuresGeometry: true) }
    @MainActor func testDarkThemeSnapshots() throws { try checkSamplePage(appearance: "dark", measuresGeometry: false) }

    @MainActor
    private func checkSamplePage(appearance: String, measuresGeometry: Bool) throws {
        let app = XCUIApplication()
        app.launchArguments = ["--database", library.databaseURL.path, "--generate-visual-sample", "--appearance", appearance,
                               "-NSWindow Frame pages-AppWindow-1", UITestLibrary.startWindowFrame]
        app.launch()
        defer { app.terminate() }
        let window = app.windows.firstMatch
        let title = app.textFields["page-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertEqual(title.value as? String, "MyNotion — образец")
        try resize(window, to: Self.windowSize)
        if measuresGeometry { try checkGeometry(of: app, title: title) }

        // Снимок окна для пары «Notion / MyNotion»: мышь уводим с текста, чтобы ручек не было.
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.99)).hover()
        let screenshot = window.screenshot()
        attach(screenshot, named: "mynotion-\(appearance)-page")
        // Исполнитель UI-тестов в «песочнице»: пишет только в свою временную папку.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mynotion-visual-reference", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("mynotion-\(appearance)-page.png")
        try screenshot.pngRepresentation.write(to: file)
        print("Снимок образца: \(file.path)")

        try checkBrightness(of: app, appearance: appearance)
    }

    @MainActor
    private func checkGeometry(of app: XCUIApplication, title: XCUIElement) throws {
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
    }

    /// Дерево и редактор: снимки и яркость фона — светлый в светлой теме, тёмный в тёмной. Окно снято выше.
    @MainActor
    private func checkBrightness(of app: XCUIApplication, appearance: String) throws {
        let parts: [(String, XCUIElement)] = [
            ("tree", app.outlines["page-tree"]),
            ("editor", app.textViews["page-body"]),
        ]
        for (name, element) in parts {
            let screenshot = element.screenshot()
            attach(screenshot, named: "\(name)-\(appearance)")
            let brightness = try XCTUnwrap(Self.medianBrightness(of: screenshot.image), "Снимок \(name) не читается")
            if appearance == "dark" {
                XCTAssertLessThan(brightness, 0.35, "\(name): фон не тёмный в тёмной теме (\(brightness))")
            } else {
                XCTAssertGreaterThan(brightness, 0.85, "\(name): фон не светлый в светлой теме (\(brightness))")
            }
        }
    }

    private func attach(_ screenshot: XCUIScreenshot, named name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Медиана яркости точек снимка: фон занимает большую часть, текст её не сдвигает.
    private static func medianBrightness(of image: NSImage) -> CGFloat? {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        var values: [CGFloat] = []
        let step = max(1, min(bitmap.pixelsWide, bitmap.pixelsHigh) / 40)
        for x in stride(from: 0, to: bitmap.pixelsWide, by: step) {
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: step) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                values.append(0.299 * color.redComponent + 0.587 * color.greenComponent + 0.114 * color.blueComponent)
            }
        }
        guard !values.isEmpty else { return nil }
        return values.sorted()[values.count / 2]
    }

    /// Окно 1440×900: левый верхний угол тянется к углу экрана под строкой меню, затем правый нижний — до размера.
    @MainActor
    private func resize(_ window: XCUIElement, to size: CGSize) throws {
        let frame = window.frame
        let topLeft = window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 1, dy: 1))
        topLeft.click(forDuration: 0.2, thenDragTo: topLeft.withOffset(CGVector(dx: -frame.minX, dy: 40 - frame.minY)))
        // Окно помнит размер прошлого запуска, а перетаскивание не всегда доходит до места: тянуть, пока не совпадёт.
        // Большое окно уменьшается за левый верхний угол: правый нижний у края экрана, там всплывает Dock и забирает мышь.
        for _ in 0..<4 {
            let moved = window.frame
            let dx = size.width - moved.width, dy = size.height - moved.height
            guard abs(dx) > Self.tolerance || abs(dy) > Self.tolerance else { break }
            // Что уменьшить — за левый верхний угол (тянуть внутрь), что увеличить — за правый нижний.
            let shrink = CGVector(dx: min(dx, 0), dy: min(dy, 0)), grow = CGVector(dx: max(dx, 0), dy: max(dy, 0))
            if shrink.dx != 0 || shrink.dy != 0 {
                let corner = window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 1, dy: 1))
                corner.click(forDuration: 0.2, thenDragTo: corner.withOffset(CGVector(dx: -shrink.dx, dy: -shrink.dy)))
            } else if grow.dx != 0 {
                // Правый край посередине: угол бывает у нижнего края экрана.
                let edge = window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: moved.width - 1, dy: moved.height / 2))
                edge.click(forDuration: 0.2, thenDragTo: edge.withOffset(CGVector(dx: grow.dx, dy: 0)))
            } else {
                let edge = window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: moved.width / 2, dy: moved.height - 1))
                edge.click(forDuration: 0.2, thenDragTo: edge.withOffset(CGVector(dx: 0, dy: grow.dy)))
            }
        }
        XCTAssertEqual(window.frame.width, size.width, accuracy: Self.tolerance, "Ширина окна")
        XCTAssertEqual(window.frame.height, size.height, accuracy: Self.tolerance, "Высота окна")
    }
}
