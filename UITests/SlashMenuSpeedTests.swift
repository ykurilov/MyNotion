import XCTest

/// SC-101: любой новый блок 002 создаётся через «/» не дольше 3 секунд набора — от первого знака «/» до блока на странице.
/// Картинка, файл, видео и закладка дальше ждут файл или адрес: для них конец набора — открывшееся окно вставки,
/// а у видео и закладки ещё вставляется адрес, чтобы проверить, что блок записался. Каждый тип — на своей странице.
final class SlashMenuSpeedTests: XCTestCase {
    private var library: UITestLibrary!

    override func setUpWithError() throws {
        continueAfterFailure = false
        library = try UITestLibrary.make(for: self)
    }

    /// Тип блока, что набирается после «/», и что на странице значит «блок готов».
    private struct Case {
        enum Done { case menuClosed, element(String), insertWindow(link: String?) }
        var kind: String
        var query: String
        var done: Done
        var popupItem: String? = nil
    }

    private let cases: [Case] = [
        Case(kind: "toggle", query: "раскрыв", done: .menuClosed),
        Case(kind: "quote", query: "цитата", done: .menuClosed),
        Case(kind: "callout", query: "выноска", done: .menuClosed),
        Case(kind: "divider", query: "раздел", done: .menuClosed),
        Case(kind: "code", query: "код", done: .element("code-editor")),
        Case(kind: "equation", query: "формула", done: .element("equation-field")),
        Case(kind: "tableOfContents", query: "оглавление", done: .element("table-of-contents")),
        Case(kind: "table", query: "таблица", done: .menuClosed),
        Case(kind: "columnList", query: "колонки 2", done: .menuClosed, popupItem: "columns-2"),
        Case(kind: "image", query: "картинка", done: .insertWindow(link: nil)),
        Case(kind: "file", query: "файл", done: .insertWindow(link: nil)),
        Case(kind: "video", query: "видео", done: .insertWindow(link: "https://youtu.be/dQw4w9WgXcQ")),
        Case(kind: "bookmark", query: "закладка", done: .insertWindow(link: "https://example.com")),
    ]

    @MainActor
    func testEveryNewBlockFromSlashWithinThreeSeconds() throws {
        let app = library.launchApp()
        var timings: [(String, TimeInterval)] = []
        var savedKinds: [String: String] = [:]
        for item in cases {
            let title = "Меню «/»: \(item.kind)"
            app.createPage(titled: title)
            let started = Date()
            app.typeText("/" + item.query)
            let typed = Date()
            let menuItem = app.popupItem(item.popupItem ?? item.kind)
            XCTAssertTrue(poll { menuItem.exists }, "Меню «/» не нашло «\(item.query)»")
            let menuShown = Date()
            app.typeKey(.return, modifierFlags: [])
            let entered = Date()
            switch item.done {
            case .menuClosed:
                XCTAssertTrue(poll { !menuItem.exists }, "Меню «/» не закрылось: \(item.kind)")
            case .element(let identifier):
                XCTAssertTrue(poll { app.descendants(matching: .any)[identifier].exists }, "Нет «\(identifier)»")
            case .insertWindow:
                XCTAssertTrue(poll { app.textFields["insert-link-field"].exists }, "Нет окна вставки: \(item.kind)")
            }
            let elapsed = Date().timeIntervalSince(started)
            timings.append((item.kind, elapsed))
            print("Проба «/»: \(item.kind) набор \(ms(typed, started)) меню \(ms(menuShown, typed)) Enter \(ms(entered, menuShown)) блок \(ms(Date(), entered)) мс")

            // После замера: формула получает запись, видео и закладка — адрес; картинке и файлу окно закрывается.
            switch item.done {
            case .element("equation-field"):
                app.typeText("x^2\r")
            case .insertWindow(let link?):
                let field = app.textFields["insert-link-field"]
                field.click()
                field.typeText(link + "\r")
            case .insertWindow(nil):
                app.typeKey(.escape, modifierFlags: [])
            default:
                break
            }
            if case .insertWindow(nil) = item.done { continue }
            savedKinds[title] = item.kind
        }
        app.quit()

        for (kind, elapsed) in timings {
            print("Набор «/»: \(kind) — \(Int((elapsed * 1_000).rounded())) мс")
        }
        let slow = timings.filter { $0.1 > 3 }
        XCTAssertTrue(slow.isEmpty, "Дольше 3 с: \(slow.map { "\($0.0) \(String(format: "%.2f", $0.1)) с" })")
        for (title, kind) in savedKinds {
            XCTAssertTrue(try library.savedBlocks(ofPage: title).contains { $0.kind == kind }, "На странице «\(title)» нет блока \(kind)")
        }
    }

    private func ms(_ end: Date, _ start: Date) -> Int { Int((end.timeIntervalSince(start) * 1_000).rounded()) }

    /// Частая проверка вместо `waitForExistence`: ожидание XCTest проверяет условие раз в секунду,
    /// и эта секунда попадала бы в замер. Каждая проверка `exists` — свежий снимок окна, ≈ 50 мс.
    private func poll(timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
        } while Date() < deadline
        return condition()
    }
}
