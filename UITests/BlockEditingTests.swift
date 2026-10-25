import XCTest

/// Оформление блоками вживую (сценарии 3.1–3.5 из spec.md): все типы блоков, меню «/» с поиском,
/// щелчок по чекбоксу, ручки «+ ⋮⋮» при наведении, перетаскивание за «⋮⋮», ⌘Z/⇧⌘Z и перезапуск.
/// Логика каждого действия проверена модульными тестами PageEditorTests; здесь — что части работают вместе.
final class BlockEditingTests: XCTestCase {
    private var library: UITestLibrary!

    override func setUpWithError() throws {
        continueAfterFailure = false
        library = try UITestLibrary.make(for: self)
    }

    /// 3.1 и 3.2: все типы через быстрые символы и меню «/», Esc закрывает меню, перезапуск сохраняет типы.
    @MainActor
    func testAllBlockKindsShortcutsAndSlashMenuSurviveRelaunch() throws {
        var app = library.launchApp()
        app.createPage(titled: "Все блоки")
        for line in ["# Первый", "## Второй", "### Третий", "- пункт", "1. номер", "[] дело"] {
            app.typeText(line)
            app.typeKey(.return, modifierFlags: [])
        }
        // После чекбокса Enter дал чекбокс: пустой пункт Enter превращает в абзац.
        app.typeKey(.return, modifierFlags: [])
        app.typeText("абзац")
        app.typeKey(.return, modifierFlags: [])

        // Меню «/»: поиск сужает список, Enter выбирает.
        app.typeText("/")
        XCTAssertTrue(app.popupItem("heading1").waitForExistence(timeout: 5), "Меню «/» не открылось")
        app.typeText("чек")
        XCTAssertTrue(app.popupItem("checkbox").waitForExistence(timeout: 2))
        XCTAssertFalse(app.popupItem("heading1").exists, "Поиск не сузил меню")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertFalse(app.popupItem("checkbox").waitForExistence(timeout: 1), "Меню не закрылось после выбора")
        app.typeText("из меню")

        // Esc закрывает меню и оставляет набранное.
        app.typeKey(.return, modifierFlags: [])
        app.typeText("/заг")
        XCTAssertTrue(app.popupItem("heading1").waitForExistence(timeout: 2), "Поиск «заг» не нашёл заголовки")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(app.popupItem("heading1").waitForExistence(timeout: 1), "Esc не закрыл меню")

        app.quit()
        let expected: [UITestLibrary.SavedBlock] = [
            .init(kind: "heading1", text: "Первый"),
            .init(kind: "heading2", text: "Второй"),
            .init(kind: "heading3", text: "Третий"),
            .init(kind: "bulletItem", text: "пункт"),
            .init(kind: "numberedItem", text: "номер"),
            .init(kind: "checkbox", text: "дело"),
            .init(kind: "paragraph", text: "абзац"),
            .init(kind: "checkbox", text: "из меню"),
            .init(kind: "checkbox", text: "/заг"),
        ]
        XCTAssertEqual(try library.savedBlocks(ofPage: "Все блоки"), expected)

        app = library.launchApp()
        XCTAssertTrue(app.pageBody.waitForExistence(timeout: 10))
        XCTAssertEqual(app.pageBody.value as? String, "Первый\nВторой\nТретий\nпункт\nномер\nдело\nабзац\nиз меню\n/заг")
        app.terminate()
    }

    /// 3.3: щелчок по квадрату чекбокса отмечает его, ⌘Z снимает отметку.
    @MainActor
    func testClickingCheckboxTogglesIt() throws {
        let app = library.launchApp()
        app.createPage(titled: "Дела")
        app.typeText("[] купить хлеб")

        XCTAssertTrue(app.hoverFirstBlock(), "Ручки блока не появились при наведении")
        // Квадрат — в колонке маркера сразу правее «⋮⋮» (contracts/visual-style.md, «Ручки блока»).
        let handle = app.blockDragHandle.frame
        let body = app.pageBody
        body.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: handle.maxX + 24 - body.frame.minX, dy: handle.midY - body.frame.minY))
            .click()
        app.typeKey("z", modifierFlags: .command)
        app.typeKey("z", modifierFlags: [.command, .shift])

        app.quit()
        XCTAssertEqual(try library.savedBlocks(ofPage: "Дела"), [.init(kind: "checkbox", text: "купить хлеб", isChecked: true)])
    }

    /// 3.4 и 3.5: ручки при наведении, «+» добавляет блок с меню «/», перетаскивание за «⋮⋮»,
    /// ⌘Z возвращает порядок, ⇧⌘Z повторяет, после перезапуска порядок тот же.
    @MainActor
    func testDragBlockByHandleUndoRedoAndRelaunch() throws {
        var app = library.launchApp()
        app.createPage(titled: "Порядок")
        app.typeText("один")
        app.typeKey(.return, modifierFlags: [])
        app.typeText("два")
        app.typeKey(.return, modifierFlags: [])
        app.typeText("три")

        XCTAssertTrue(app.hoverFirstBlock(), "Ручки блока не появились при наведении")
        XCTAssertTrue(app.blockAddHandle.exists, "Нет кнопки «+»")

        // Тянуть «один» за «⋮⋮» ниже «три».
        let handle = app.blockDragHandle
        let lineHeight = handle.frame.height
        let grip = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        grip.click(forDuration: 0.3, thenDragTo: grip.withOffset(CGVector(dx: 0, dy: lineHeight * 3)))
        XCTAssertEqual(app.pageBody.value as? String, "два\nтри\nодин", "Блок не переставился")

        app.typeKey("z", modifierFlags: .command)
        XCTAssertEqual(app.pageBody.value as? String, "один\nдва\nтри", "⌘Z не вернул порядок")
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertEqual(app.pageBody.value as? String, "два\nтри\nодин", "⇧⌘Z не повторил перестановку")

        // «+» у первого блока: пустой блок ниже и меню «/».
        XCTAssertTrue(app.hoverFirstBlock())
        app.blockAddHandle.click()
        XCTAssertTrue(app.popupItem("heading1").waitForExistence(timeout: 2), "«+» не открыл меню «/»")
        app.typeKey(.escape, modifierFlags: [])

        app.quit()
        XCTAssertEqual(try library.savedBlocks(ofPage: "Порядок").map(\.text), ["два", "/", "три", "один"])

        app = library.launchApp()
        XCTAssertTrue(app.pageBody.waitForExistence(timeout: 10))
        XCTAssertEqual(app.pageBody.value as? String, "два\n/\nтри\nодин")
        app.terminate()
    }
}
