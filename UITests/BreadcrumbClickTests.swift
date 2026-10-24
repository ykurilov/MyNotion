import XCTest

/// Путь над страницей нажимается: предок открывается в текущей вкладке с историей «назад/вперёд»,
/// текущая страница не реагирует. Рука и подсветка — в `scripts/imac/real-cursor-check.zsh` (настоящая мышь).
final class BreadcrumbClickTests: XCTestCase {
    private var library: UITestLibrary!

    override func setUpWithError() throws {
        continueAfterFailure = false
        library = try UITestLibrary.make(for: self)
    }

    @MainActor
    func testClickingAncestorOpensItWithHistory() throws {
        let app = library.launchApp()
        app.createPage(titled: "Проекты")
        app.typeText("до")
        app.typeKey(.return, modifierFlags: [])
        app.typeText("/стр")
        XCTAssertTrue(app.popupItem("pageLink").waitForExistence(timeout: 5), "В меню «/» нет «Страница»")
        app.typeKey(.return, modifierFlags: [])
        app.typeText("План")

        let current = app.staticTexts["page-breadcrumb"], ancestor = app.buttons["breadcrumb-ancestor"]
        XCTAssertTrue(waitUntil { ancestor.exists && ancestor.label == "Проекты" && current.label == "План" },
                      "Путь «Проекты / План» не показан: \(ancestor.exists ? ancestor.label : "-") / \(current.label)")

        // Текущая страница не нажимается.
        current.click()
        XCTAssertEqual(current.label, "План")

        ancestor.click()
        XCTAssertTrue(waitUntil { current.label == "Проекты" && !ancestor.exists }, "Щелчок по предку не открыл «Проекты»: \(current.label)")

        // Обычный переход: «назад» возвращает на «План», «вперёд» — снова на «Проекты».
        app.typeKey("[", modifierFlags: .command)
        XCTAssertTrue(waitUntil { current.label == "План" }, "«Назад» не вернул на «План»: \(current.label)")
        app.typeKey("]", modifierFlags: .command)
        XCTAssertTrue(waitUntil { current.label == "Проекты" }, "«Вперёд» не открыл «Проекты»: \(current.label)")
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }
}
