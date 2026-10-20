import XCTest

/// US5 «Ссылки» вживую (003): под названием «↗ N обратных ссылок», список источников, переход к странице-источнику,
/// счёт после стирания упоминания и после корзины. Индекс и запросы на уровне данных — `PageLinkIndexTests`, `BacklinksQueryTests`.
final class BacklinksTests: XCTestCase {
    private var library: UITestLibrary!

    override func setUpWithError() throws {
        continueAfterFailure = false
        library = try UITestLibrary.make(for: self)
    }

    @MainActor
    func testBacklinksRowListAndCounts() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--database", library.databaseURL.path, "--generate-003-sample",
                               "-NSWindow Frame pages-AppWindow-1", UITestLibrary.startWindowFrame]
        app.launch()
        XCTAssertTrue(app.outlines["page-tree"].waitForExistence(timeout: 20))

        // «цель»: на неё ссылаются «А» (упоминание), «В» (упоминание) и «Г» (блок-ссылка).
        open(app, "Ссылки: цель")
        waitForRow(app, "3 обратные ссылки")

        // Щелчок по строке — список из трёх страниц; пункт «А» открывает «А».
        clickRow(app)
        let items = app.descendants(matching: .any).matching(identifier: "backlink-item")
        XCTAssertTrue(items.firstMatch.waitForExistence(timeout: 5), "Список обратных ссылок не открылся")
        XCTAssertEqual(items.count, 3)
        items.matching(NSPredicate(format: "label == %@", "Ссылки: А")).firstMatch.click()
        waitForTitle(app, "Ссылки: А")

        // Упоминание на «В» стёрто — у «цели» две.
        open(app, "Ссылки: В")
        app.pageBody.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 40, dy: 10)).click()
        app.typeKey(.rightArrow, modifierFlags: .command)
        app.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(waitForBody(app) { !$0.contains("Ссылки: цель") }, "Упоминание осталось: \(app.pageBody.value ?? "")")
        open(app, "Ссылки: цель")
        waitForRow(app, "2 обратные ссылки")

        // «Г» в корзину из меню строки панели, пока открыта «цель», — счёт меняется сразу, без перехода (как в Notion).
        let sourceRow = app.outlines["page-tree"].outlineRows.containing(NSPredicate(format: "value == %@", "Ссылки: Г")).firstMatch
        XCTAssertTrue(sourceRow.waitForExistence(timeout: 5), "В панели нет строки «Ссылки: Г»")
        scrollIntoView(app, sourceRow)
        sourceRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
        XCTAssertTrue(app.menuItems["Удалить в корзину"].waitForExistence(timeout: 5), "В меню строки нет «Удалить в корзину»")
        app.menuItems["Удалить в корзину"].click()
        XCTAssertEqual(currentTitle(app), "Ссылки: цель")
        waitForRow(app, "1 обратная ссылка")

        // Страница с 30 источниками: счёт и прокручиваемый список.
        open(app, "Ссылки: популярная")
        waitForRow(app, "30 обратных ссылок")
        clickRow(app)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "backlink-item").firstMatch.waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])

        // Страница без обратных ссылок — без строки.
        open(app, "Ссылки: А")
        XCTAssertFalse(row(app).waitForExistence(timeout: 2), "У страницы без обратных ссылок есть строка")
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
    }

    // MARK: Помощники

    /// Строка дерева ниже видимой части панели «доступна» для XCUITest, но щелчок по ней попадает мимо:
    /// прокручиваем панель, пока рамка строки не окажется внутри видимой части.
    @MainActor
    private func scrollIntoView(_ app: XCUIApplication, _ row: XCUIElement) {
        let clip = app.scrollViews.containing(.outline, identifier: "page-tree").firstMatch
        XCTAssertTrue(clip.exists, "Нет прокрутки панели")
        for _ in 0..<20 {
            let visible = clip.frame, frame = row.frame
            if frame.minY >= visible.minY, frame.maxY <= visible.maxY { return }
            clip.scroll(byDeltaX: 0, deltaY: frame.maxY > visible.maxY ? -40 : 40)
        }
        XCTFail("Строка «\(row.debugDescription)» не видна в панели")
    }

    @MainActor
    private func row(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["backlinks-row"]
    }

    /// Подложка строки — только по тексту, а строка шириной в страницу: щелчок — у левого края.
    @MainActor
    private func clickRow(_ app: XCUIApplication) {
        row(app).coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 40, dy: 12)).click()
    }

    @MainActor
    private func waitForRow(_ app: XCUIApplication, _ label: String) {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if row(app).exists, row(app).label == label { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("Ждали строку «\(label)», есть «\(row(app).exists ? row(app).label : "нет строки")»")
    }

    /// Страницы образца далеко внизу панели: открываем через поиск (⇧⌘F, Enter).
    @MainActor
    private func open(_ app: XCUIApplication, _ title: String) {
        if currentTitle(app) == title { return }
        app.typeKey("f", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.textFields["sidebar-search"].waitForExistence(timeout: 5), "Нет поля поиска")
        app.typeText(title)
        XCTAssertTrue(app.descendants(matching: .any)["search-results-list"].waitForExistence(timeout: 5), "Выдача не появилась")
        app.typeKey(.return, modifierFlags: [])
        waitForTitle(app, title)
    }

    @MainActor
    private func currentTitle(_ app: XCUIApplication) -> String? {
        let field = app.textFields["page-title"]
        return field.exists ? field.value as? String : nil
    }

    @MainActor
    private func waitForTitle(_ app: XCUIApplication, _ title: String) {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if currentTitle(app) == title { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("Открыта «\(currentTitle(app) ?? "nil")», ждали «\(title)»")
    }

    @MainActor
    private func waitForBody(_ app: XCUIApplication, _ matches: (String) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if matches(app.pageBody.value as? String ?? "") { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }
}
