import AppKit
import XCTest

/// Вставка ⌘V ответа ИИ в Markdown вживую: заголовок, список, жирный — блоками, одна ⌘Z убирает всё.
/// Разбор и слияние с абзацем проверены модульными тестами `PastedTextTests` и `PasteBlocksTests`.
final class PasteMarkdownTests: XCTestCase {
    private var library: UITestLibrary!

    override func setUpWithError() throws {
        continueAfterFailure = false
        library = try UITestLibrary.make(for: self)
    }

    @MainActor
    func testPastingMarkdownMakesHeadingListAndBold() throws {
        let app = library.launchApp()
        app.createPage(titled: "Вставка")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("## План\n\nСначала **главное**:\n\n- первый\n- второй\n", forType: .string)
        app.typeKey("v", modifierFlags: .command)
        XCTAssertTrue(waitUntil { app.pageBody.value as? String == "План\nСначала главное:\nпервый\nвторой" },
                      "Markdown не стал блоками: \(app.pageBody.value ?? "")")

        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(waitUntil { (app.pageBody.value as? String)?.isEmpty == true }, "⌘Z убрала не всю вставку: \(app.pageBody.value ?? "")")
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitUntil { app.pageBody.value as? String == "План\nСначала главное:\nпервый\nвторой" })

        app.quit()
        XCTAssertEqual(try library.savedBlocks(ofPage: "Вставка").map(\.kind), ["heading2", "paragraph", "bulletItem", "bulletItem"])
        XCTAssertTrue(try library.savedTextStyles(ofPage: "Вставка")[1].contains("bold"), "Нет жирного")
    }

    /// Ответ чата, выделенный мышью: в буфере отрисованный HTML, а простой текст — без значков Markdown.
    @MainActor
    func testPastingChatHTMLMakesHeadingListAndBold() throws {
        let app = library.launchApp()
        app.createPage(titled: "Вставка HTML")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("<meta charset='utf-8'><h2 style=\"margin: 0\">План</h2><p>Сначала <strong>главное</strong>:</p>"
            + "<ul><li>первый<ul><li>вложенный</li></ul></li><li>второй</li></ul>", forType: .html)
        pasteboard.setString("План\nСначала главное:\n\nпервый\nвложенный\nвторой", forType: .string)
        app.typeKey("v", modifierFlags: .command)
        XCTAssertTrue(waitUntil { app.pageBody.value as? String == "План\nСначала главное:\nпервый\nвложенный\nвторой" },
                      "HTML не стал блоками: \(app.pageBody.value ?? "")")

        app.quit()
        let saved = try library.savedBlocks(ofPage: "Вставка HTML")
        XCTAssertEqual(saved.map(\.kind), ["heading2", "paragraph", "bulletItem", "bulletItem", "bulletItem"])
        XCTAssertEqual(saved.map(\.indent), [0, 0, 0, 1, 0])
        XCTAssertTrue(try library.savedTextStyles(ofPage: "Вставка HTML")[1].contains("bold"), "Нет жирного")
    }

    /// Копирование внутри страницы, как в Notion: ⌘C заголовка и вложенного списка, ⌘V ниже — те же блоки,
    /// а в простом тексте буфера — Markdown для других программ.
    @MainActor
    func testCopyingListInsidePageKeepsBlocks() throws {
        let app = library.launchApp()
        app.createPage(titled: "Копия списка")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("## План\n\n- **первый**\n  - вложенный\n- [x] сделано\n\nконец", forType: .string)
        app.typeKey("v", modifierFlags: .command)
        let original = "План\nпервый\nвложенный\nсделано\nконец"
        XCTAssertTrue(waitUntil { app.pageBody.value as? String == original }, "Страница не собралась: \(app.pageBody.value ?? "")")

        app.typeKey("a", modifierFlags: .command)
        app.typeKey("c", modifierFlags: .command)
        XCTAssertTrue(waitUntil { pasteboard.string(forType: .string)?.contains("- **первый**\n  - вложенный") == true },
                      "В буфере не Markdown: \(pasteboard.string(forType: .string) ?? "")")
        XCTAssertNotNil(pasteboard.data(forType: NSPasteboard.PasteboardType("ru.kurilov.mynotion.blocks")), "Нет своего типа блоков")
        app.typeKey(.downArrow, modifierFlags: .command)
        app.typeKey(.return, modifierFlags: [])
        app.typeKey("v", modifierFlags: .command)
        XCTAssertTrue(waitUntil { app.pageBody.value as? String == original + "\n" + original },
                      "Копия встала не блоками: \(app.pageBody.value ?? "")")

        app.quit()
        let saved = try library.savedBlocks(ofPage: "Копия списка")
        let kinds = ["heading2", "bulletItem", "bulletItem", "checkbox", "paragraph"]
        XCTAssertEqual(saved.map(\.kind), kinds + kinds)
        XCTAssertEqual(saved.map(\.indent), [0, 0, 1, 0, 0, 0, 0, 1, 0, 0])
        XCTAssertTrue(try library.savedTextStyles(ofPage: "Копия списка")[6].contains("bold"), "У копии нет жирного")
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
