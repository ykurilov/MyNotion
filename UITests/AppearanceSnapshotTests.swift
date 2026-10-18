import AppKit
import XCTest

/// FR-028: светлая и тёмная тема. Окно, дерево и редактор снимаются в обеих темах (вложения прогона);
/// по снимкам проверяется, что фон страницы и панели — светлый в светлой теме и тёмный в тёмной.
/// Полосы («Изменения не сохранены», синхронизация, импорт) и окно «Две версии» в обеих темах снимает
/// галерея состояний (`scripts/vm/run-in-vm.sh gallery`).
final class AppearanceSnapshotTests: XCTestCase {
    private var library: UITestLibrary!

    override func setUpWithError() throws {
        continueAfterFailure = true
        library = try UITestLibrary.make(for: self)
    }

    @MainActor func testLightTheme() throws { try snapshot(appearance: "light", expectDark: false) }
    @MainActor func testDarkTheme() throws { try snapshot(appearance: "dark", expectDark: true) }

    @MainActor
    private func snapshot(appearance: String, expectDark: Bool) throws {
        let app = XCUIApplication()
        app.launchArguments = ["--database", library.databaseURL.path, "--generate-visual-sample", "--appearance", appearance]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.textViews["page-body"].waitForExistence(timeout: 10))
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.99)).hover()

        let parts: [(String, XCUIElement)] = [
            ("window", app.windows.firstMatch),
            ("tree", app.outlines["page-tree"]),
            ("editor", app.textViews["page-body"]),
        ]
        for (name, element) in parts {
            let screenshot = element.screenshot()
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = "\(name)-\(appearance)"
            attachment.lifetime = .keepAlways
            add(attachment)
            if name != "window" {
                let brightness = try XCTUnwrap(Self.medianBrightness(of: screenshot.image), "Снимок \(name) не читается")
                if expectDark {
                    XCTAssertLessThan(brightness, 0.35, "\(name): фон не тёмный в тёмной теме (\(brightness))")
                } else {
                    XCTAssertGreaterThan(brightness, 0.85, "\(name): фон не светлый в светлой теме (\(brightness))")
                }
            }
        }
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
}
