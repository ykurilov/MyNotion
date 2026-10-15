import AppKit
import XCTest

/// Панель форматирования вживую, как в Notion (FR-033): выделил слово — под строкой панель; кнопка панели и ⌘U
/// оформляют выделение, кнопки подсвечиваются, список типов меняет тип блока; после перезапуска всё на месте.
/// Логика панели проверена модульными тестами `FormatBarTests`; здесь — что части работают вместе.
final class FormatBarTests: XCTestCase {
    private var library: UITestLibrary!

    override func setUpWithError() throws {
        continueAfterFailure = false
        library = try UITestLibrary.make(for: self)
    }

    @MainActor
    func testFormatBarStylesSelectionAndSurvivesRelaunch() throws {
        var app = library.launchApp()
        app.createPage(titled: "Оформление")
        app.typeText("раз два три")
        XCTAssertFalse(app.formatButton(.bold).exists, "Панель видна без выделения")

        // Выделить «три»: панель всплывает, кнопка «Жирный» оформляет и подсвечивается, ⌘U — подчёркивает.
        app.typeKey(.leftArrow, modifierFlags: [.option, .shift])
        XCTAssertTrue(app.formatButton(.bold).waitForExistence(timeout: 5), "Панель не всплыла у выделения")
        // Как у Notion — под строкой выделения (первая строка текста — у верха поля страницы), не над ней.
        XCTAssertGreaterThan(app.formatKind.frame.minY, app.pageBody.frame.minY + 16, "Панель не под строкой выделения")
        XCTAssertFalse(app.formatButton(.bold).isSelected)
        app.formatButton(.bold).click()
        XCTAssertTrue(app.formatButton(.bold).waitForSelected(), "Кнопка «Жирный» не подсветилась")
        app.typeKey("u", modifierFlags: .command)
        XCTAssertTrue(app.formatButton(.underline).waitForSelected(), "После ⌘U кнопка «Подчёркнутый» не подсветилась")

        // Список типов: текущий — «Текст», выбор «Заголовок 1» меняет тип блока.
        app.formatKind.click()
        XCTAssertTrue(app.popupItem("heading1").waitForExistence(timeout: 5), "Список типов не открылся")
        // Щелчок по точке пункта: обычный щелчок XCTest ищет системное меню у «выпадающего списка», а список — своё окно.
        app.popupItem("heading1").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(app.popupItem("heading1").waitForNonExistence(timeout: 5), "Список типов не закрылся")

        // Набор скрывает панель.
        app.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertTrue(app.formatButton(.bold).waitForNonExistence(timeout: 5), "Панель не скрылась без выделения")

        app.quit()
        XCTAssertEqual(try library.savedBlocks(ofPage: "Оформление").map(\.kind), ["heading1"])
        let runs = try XCTUnwrap(library.savedTextStyles(ofPage: "Оформление").first.map(Self.styleRuns))
        XCTAssertEqual(runs, [StyleRun(start: 8, length: 3, style: "bold"), StyleRun(start: 8, length: 3, style: "underline")])

        // Перезапуск: то же оформление, панель у того же слова снова показывает нажатые кнопки.
        app = library.launchApp()
        XCTAssertTrue(app.pageBody.waitForExistence(timeout: 10))
        XCTAssertEqual(app.pageBody.value as? String, "раз два три")
        app.pageBody.click()
        app.typeKey(.downArrow, modifierFlags: .command)
        app.typeKey(.leftArrow, modifierFlags: [.option, .shift])
        XCTAssertTrue(app.formatButton(.bold).waitForSelected(), "После перезапуска «Жирный» не подсвечен")
        XCTAssertTrue(app.formatButton(.underline).isSelected, "После перезапуска «Подчёркнутый» не подсвечен")
        XCTAssertFalse(app.formatButton(.italic).isSelected)
        XCTAssertEqual(app.formatKind.label, "Заголовок 1")
        app.quit()
    }

    private struct StyleRun: Equatable {
        var start: Int
        var length: Int
        var style: String
    }

    private static func styleRuns(_ json: String) -> [StyleRun] {
        let items = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [[String: Any]] ?? []
        return items.map { StyleRun(start: $0["start"] as? Int ?? -1, length: $0["length"] as? Int ?? -1, style: $0["style"] as? String ?? "") }
    }
}

private enum FormatBarButtonID: String {
    case bold, italic, underline
}

private extension XCUIApplication {
    func formatButton(_ button: FormatBarButtonID) -> XCUIElement { descendants(matching: .any)["format-\(button.rawValue)"] }
    var formatKind: XCUIElement { descendants(matching: .any)["format-kind"] }
}

private extension XCUIElement {
    func waitForSelected(timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if exists, isSelected { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }
}
