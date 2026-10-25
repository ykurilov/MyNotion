import AppKit
import XCTest

/// Два режима выделения вживую, как в Notion: выделенный через блоки текст стирается как текст (блоки сливаются),
/// а в режиме блоков — Esc, щелчок по «⋮⋮», протяжка с поля слева — Delete убирает блоки целиком, ⌘C копирует их.
/// Логика режимов проверена модульными тестами `BlockSelectionModeTests`; здесь — что части работают вместе.
final class SelectionModesTests: XCTestCase {
    private var library: UITestLibrary!

    override func setUpWithError() throws {
        continueAfterFailure = false
        library = try UITestLibrary.make(for: self)
    }

    @MainActor
    func testTextAndBlockSelectionModesSurviveRelaunch() throws {
        let app = library.launchApp()
        app.createPage(titled: "Выделение")
        for (index, word) in ["раз", "два", "три", "четыре", "пять", "шесть"].enumerated() {
            if index > 0 { app.typeKey(.return, modifierFlags: []) }
            app.typeText(word)
        }

        // Выделение текста через границу блоков: стирается текст, «пять» и «шесть» не остаются отдельными блоками.
        for _ in 0..<6 { app.typeKey(.leftArrow, modifierFlags: .shift) }
        app.typeKey(.delete, modifierFlags: [])
        XCTAssertEqual(app.pageBody.value as? String, "раз\nдва\nтри\nчетыре\nпять", "Выделенный через блоки текст стёрся не как текст")

        // Esc выделяет блок с курсором, ↑ — блок выше, ⇧↑ — расширяет; ⌘C копирует блоки, Delete удаляет их целиком.
        // Простой текст буфера — Markdown для других программ: абзацы через пустую строку.
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey(.upArrow, modifierFlags: [])
        app.typeKey(.upArrow, modifierFlags: .shift)
        NSPasteboard.general.clearContents()
        app.typeKey("c", modifierFlags: .command)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "три\n\nчетыре", "⌘C в режиме блоков скопировал не те блоки")
        app.typeKey(.delete, modifierFlags: [])
        XCTAssertEqual(app.pageBody.value as? String, "раз\nдва\nпять", "Delete в режиме блоков удалил не те блоки")

        // Щелчок по «⋮⋮»: блок выделен и открыто его меню; Esc закрывает меню, Delete удаляет выделенный блок.
        XCTAssertTrue(app.hoverFirstBlock(), "Ручки блока не появились при наведении")
        app.blockDragHandle.click()
        XCTAssertTrue(app.popupItem("delete").waitForExistence(timeout: 5), "Меню блока не открылось")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.popupItem("delete").waitForNonExistence(timeout: 5), "Esc не закрыл меню блока")
        app.typeKey(.delete, modifierFlags: [])
        XCTAssertEqual(app.pageBody.value as? String, "два\nпять", "После «⋮⋮» и Esc Delete удалил не блок")

        // Протяжка с поля слева от «+» выделяет блок, которого коснулась; Delete удаляет его.
        XCTAssertTrue(app.hoverFirstBlock(), "Ручки блока не появились при наведении")
        let add = app.blockAddHandle.frame
        let body = app.pageBody
        let origin = body.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: add.minX - 24 - body.frame.minX, dy: add.midY - body.frame.minY))
        start.click(forDuration: 0.2, thenDragTo: start.withOffset(CGVector(dx: 16, dy: 6)))
        app.typeKey(.delete, modifierFlags: [])
        XCTAssertEqual(app.pageBody.value as? String, "пять", "Протяжка с поля не выделила блок")

        // Меню блока как у Notion: → открывает подменю «Преобразовать в» с текущим типом, ↓ и Enter меняют тип.
        XCTAssertTrue(app.hoverFirstBlock(), "Ручки блока не появились при наведении")
        app.blockDragHandle.click()
        XCTAssertTrue(app.popupItem("turn-into").waitForExistence(timeout: 5), "В меню блока нет «Преобразовать в»")
        app.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertTrue(app.popupItem("heading1").waitForExistence(timeout: 5), "Подменю «Преобразовать в» не открылось")
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.popupItem("turn-into").waitForNonExistence(timeout: 5), "Меню блока не закрылось после выбора типа")

        app.quit()
        XCTAssertEqual(try library.savedBlocks(ofPage: "Выделение").map(\.text), ["пять"])
        XCTAssertEqual(try library.savedBlocks(ofPage: "Выделение").map(\.kind), ["heading1"], "Подменю не сменило тип блока")
    }
}
