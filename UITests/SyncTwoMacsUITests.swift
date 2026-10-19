import AppKit
import SQLite3
import XCTest

/// Два Mac вживую (quickstart.md, US5): два экземпляра MyNotion со своими базами против локального сервера синхронизации.
/// Первый подключается токеном устройства и пишет код подключения, второй подключается этим кодом.
/// Правка в открытой странице одного появляется в открытой странице другого не позже чем через 10 с (SC-007).
/// Запускается сценарием `scripts/vm/sync-live-check.sh`: он поднимает сервер в виртуальном Mac и кладёт
/// в `/tmp/mn-sync-live` адрес сервера, токен первого устройства и копию приложения со своим bundle id.
final class SyncTwoMacsUITests: XCTestCase {
    private let live = URL(fileURLWithPath: "/tmp/mn-sync-live", isDirectory: true)

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard FileManager.default.fileExists(atPath: live.appendingPathComponent("server-url").path) else {
            throw XCTSkip("Нет локального сервера: запустите scripts/vm/sync-live-check.sh")
        }
    }

    @MainActor
    func testEditOnOneMacAppearsOnTheOtherWithinTenSeconds() throws {
        let server = try String(contentsOf: live.appendingPathComponent("server-url"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let code = live.appendingPathComponent("join-code")
        try? FileManager.default.removeItem(at: code)

        let first = XCUIApplication()
        first.launchArguments = ["--database", live.appendingPathComponent("mac-a/MyNotion.sqlite").path, "--generate-visual-sample",
                                 "--sync-server", server, "--sync-device-name", "Mac A", "--sync-log", live.appendingPathComponent("mac-a.log").path,
                                 "--sync-connect-token-file", live.appendingPathComponent("token").path,
                                 "--sync-write-join-code", code.path]
        first.launch()
        addTeardownBlock { @MainActor in if first.state != .notRunning { first.terminate() } }
        XCTAssertTrue(first.pageBody.waitForExistence(timeout: 15))
        XCTAssertTrue(waitFor(timeout: 20) { FileManager.default.fileExists(atPath: code.path) }, "Первый Mac не выдал код подключения")
        XCTAssertTrue(first.syncBadge.waitForExistence(timeout: 10), "Нет значка синхронизации")

        let second = XCUIApplication(url: live.appendingPathComponent("MyNotionB.app"))
        second.launchArguments = ["--database", live.appendingPathComponent("mac-b/MyNotion.sqlite").path,
                                  "--sync-server", server, "--sync-device-name", "Mac B", "--sync-log", live.appendingPathComponent("mac-b.log").path, "--sync-join-code-file", code.path]
        second.launch()
        addTeardownBlock { @MainActor in if second.state != .notRunning { second.terminate() } }
        XCTAssertTrue(second.syncBadge.waitForExistence(timeout: 20), "Второй Mac не подключился")
        XCTAssertTrue(waitFor(timeout: 15) { second.syncBadge.label == "Синхронизировано" },
                      "Второй Mac: \(second.syncBadge.label) — \(second.syncBadge.value as? String ?? "")")
        XCTAssertTrue(waitFor(timeout: 15) { first.syncBadge.label == "Синхронизировано" },
                      "Первый Mac: \(first.syncBadge.label) — \(first.syncBadge.value as? String ?? "")")
        // Образец лежит внутри «Буфера»: пустой Mac открыл первую пришедшую страницу, образец открываем в дереве.
        let sampleRow = second.outlines["page-tree"].outlineRows.containing(NSPredicate(format: "value == %@", "MyNotion — образец")).firstMatch
        XCTAssertTrue(sampleRow.waitForExistence(timeout: 20), "Страницы с первого Mac не дошли до второго")
        second.activate()
        // Середина строки — как человек; край строки XCUITest задевает кнопки раскрытия.
        sampleRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        let opened = waitFor(timeout: 10) { second.pageBodyText.contains("Заголовок первого уровня") }
        if !opened { saveScreenshots(first, second, suffix: "-failed") }
        XCTAssertTrue(opened, "Образец не открылся: \(second.pageBodyText.prefix(200)); значок: \(second.syncBadge.label) — \(second.syncBadge.value as? String ?? "")")

        // Правка на первом Mac — в открытой странице второго.
        first.activate()
        first.pageBody.click()
        first.typeKey(.downArrow, modifierFlags: .command)
        first.typeKey(.return, modifierFlags: [])
        first.typeText("Правка с Mac A")
        let started = Date()
        XCTAssertTrue(waitFor(timeout: 10) { second.pageBodyText.contains("Правка с Mac A") }, "Правка не дошла за 10 с")
        let firstDelay = Date().timeIntervalSince(started)

        // И обратно: второй Mac дописывает, первый видит.
        second.activate()
        second.pageBody.click()
        second.typeKey(.downArrow, modifierFlags: .command)
        second.typeText(" и ответ с Mac B")
        let back = Date()
        XCTAssertTrue(waitFor(timeout: 10) { first.pageBodyText.contains("Правка с Mac A и ответ с Mac B") }, "Ответ не дошёл за 10 с")
        let secondDelay = Date().timeIntervalSince(back)

        XCTAssertTrue(waitFor(timeout: 10) { first.syncBadge.label == "Синхронизировано" && second.syncBadge.label == "Синхронизировано" },
                      "Значок: \(first.syncBadge.label) / \(second.syncBadge.label)")
        print("Задержка синхронизации: A→B \(String(format: "%.2f", firstDelay)) с, B→A \(String(format: "%.2f", secondDelay)) с")

        // Картинка (US5): вставлена на первом Mac — на втором появляется файл с теми же байтами (части зашифрованы,
        // идут через сервер), и вид картинки на открытой странице.
        let picture = FileManager.default.temporaryDirectory.appendingPathComponent("Снимок с Mac A.png")
        let bytes = Self.png(width: 800, height: 450)
        try bytes.write(to: picture)
        first.activate()
        first.pageBody.click()
        first.typeKey(.downArrow, modifierFlags: .command)
        first.typeKey(.return, modifierFlags: [])
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([picture as NSURL])
        first.typeKey("v", modifierFlags: .command)
        let sent = Date()
        let arrived = waitFor(timeout: 60) { (try? self.attachmentCopy(of: "mac-b", named: "Снимок с Mac A.png")) == bytes }
        if !arrived { saveScreenshots(first, second, suffix: "-picture-failed") }
        XCTAssertTrue(arrived, "Картинка не дошла до второго Mac за 60 с")
        print("Картинка A→B: \(String(format: "%.2f", Date().timeIntervalSince(sent))) с")
        second.activate()
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        saveScreenshots(first, second)
    }

    /// Копия файла на «Mac» по базе экземпляра: строка `attachment` с путём и сам файл в его `Attachments/`.
    private func attachmentCopy(of mac: String, named name: String) throws -> Data? {
        let folder = live.appendingPathComponent(mac, isDirectory: true)
        var database: OpaquePointer?
        guard sqlite3_open_v2(folder.appendingPathComponent("MyNotion.sqlite").path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT localPath FROM attachment WHERE localPath LIKE ?", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, "%/" + name, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_ROW, let path = sqlite3_column_text(statement, 0) else { return nil }
        return try? Data(contentsOf: folder.appendingPathComponent("Attachments").appendingPathComponent(String(cString: path)))
    }

    private static func png(width: Int, height: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGradient(starting: .systemOrange, ending: .systemPurple)?.draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: 30)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    /// Снимки обоих окон — вложениями отчёта; сценарий выгружает их из .xcresult.
    private func saveScreenshots(_ first: XCUIApplication, _ second: XCUIApplication, suffix: String = "") {
        for (name, app) in [("mac-a", first), ("mac-b", second)] {
            let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            attachment.name = name + suffix
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    private func waitFor(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }
}

private extension XCUIApplication {
    var syncBadge: XCUIElement { buttons["sidebar-sync-status"] }
    var pageBodyText: String { (pageBody.exists ? pageBody.value as? String : nil) ?? "" }
}
