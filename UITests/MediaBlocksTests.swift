import AppKit
import SQLite3
import XCTest

/// Картинки, файлы, видео и закладки вживую (US5, Independent Test): картинка из Finder (файлом через буфер — так же,
/// как перетаскивание, вставка идёт одним путём) и из буфера, PDF, видео, YouTube по ссылке, закладка через «/»;
/// оригинал удалён — копия на месте и открывается после перезапуска; файл больше 100 МБ — сообщение, блока нет.
/// Логика каждого шага — в модульных тестах PageEditorTests и AttachmentsTests; здесь — что части работают вместе.
final class MediaBlocksTests: XCTestCase {
    private var library: UITestLibrary!
    private var folder: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        library = try UITestLibrary.make(for: self)
        folder = library.databaseURL.deletingLastPathComponent().appendingPathComponent("Оригиналы", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    @MainActor
    func testMediaBlocksSurviveRelaunchAndDeletedOriginal() throws {
        let png = try write("Снимок экрана.png", Self.png(width: 320, height: 180))
        let pdf = try write("Договор.pdf", Data("%PDF-1.4\n% образец\n".utf8))
        let movie = try write("Ролик.mov", Data(repeating: 7, count: 4_096))
        let huge = folder.appendingPathComponent("Огромный.mov")
        FileManager.default.createFile(atPath: huge.path, contents: nil)
        let handle = try FileHandle(forWritingTo: huge)
        try handle.truncate(atOffset: 104_857_601)
        try handle.close()

        var app = library.launchApp()
        app.createPage(titled: "Медиа")
        app.typeText("Начало")
        app.typeKey(.return, modifierFlags: [])

        // Картинка из Finder (файл в буфере), картинка из буфера, PDF и видео.
        paste(app, files: [png])
        XCTAssertTrue(waitUntil { (try? self.attachmentCount()) == 1 }, "Картинка из Finder не скопировалась")
        paste(app, image: try Data(contentsOf: png))
        XCTAssertTrue(waitUntil { (try? self.attachmentCount()) == 2 }, "Картинка из буфера не записалась")
        paste(app, files: [pdf, movie])
        XCTAssertTrue(waitUntil { (try? self.attachmentCount()) == 4 }, "PDF и видео не скопировались")

        // Ссылка на YouTube в пустой строке — меню «Встроить видео».
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("https://youtu.be/dQw4w9WgXcQ", forType: .string)
        app.typeKey("v", modifierFlags: .command)
        let embed = app.popupItem("video")
        XCTAssertTrue(embed.waitForExistence(timeout: 5), "Нет меню «Встроить видео / Закладка / Ссылка»")
        embed.click()

        // Закладка через «/»: окно с полем адреса.
        app.typeText("/закладка")
        XCTAssertTrue(app.popupItem("bookmark").waitForExistence(timeout: 5), "Меню «/» не нашло закладку")
        app.typeKey(.return, modifierFlags: [])
        let field = app.textFields["insert-link-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Нет окна вставки ссылки")
        field.click()
        field.typeText("https://example.com\r")
        XCTAssertTrue(waitUntil { (try? self.library.savedBlocks(ofPage: "Медиа").map(\.kind).contains("bookmark")) == true },
                      "Закладка не появилась")

        // Больше 100 МБ — сообщение, блок не создаётся.
        paste(app, files: [huge])
        let message = app.staticTexts["Файл больше 100 МБ — MyNotion такие не хранит"]
        XCTAssertTrue(message.waitForExistence(timeout: 10), "Нет сообщения о 100 МБ")
        app.buttons["Понятно"].click()

        app.quit()
        XCTAssertEqual(try library.savedBlocks(ofPage: "Медиа").map(\.kind),
                       ["paragraph", "image", "image", "file", "video", "video", "bookmark", "paragraph"])

        // Оригинал удалён в Finder — копия на месте, приложение после перезапуска её показывает.
        try FileManager.default.removeItem(at: png)
        app = library.launchApp()
        XCTAssertTrue(app.pageBody.waitForExistence(timeout: 10))
        let copies = try attachmentCopies()
        XCTAssertEqual(copies.count, 4)
        let pngCopy = try XCTUnwrap(copies.first { $0.lastPathComponent == "Снимок экрана.png" })
        XCTAssertEqual(try Data(contentsOf: pngCopy), Self.png(width: 320, height: 180))
        XCTAssertNotNil(NSImage(contentsOf: pngCopy), "Копия картинки не открывается")
        app.quit()
    }

    // MARK: Буфер

    @MainActor
    private func paste(_ app: XCUIApplication, files: [URL]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(files as [NSURL])
        app.typeKey("v", modifierFlags: .command)
    }

    @MainActor
    private func paste(_ app: XCUIApplication, image: Data) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(image, forType: .png)
        app.typeKey("v", modifierFlags: .command)
    }

    // MARK: Файлы и база

    private func write(_ name: String, _ data: Data) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private static func png(width: Int, height: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for x in 0..<width { for y in 0..<height { rep.setColor(NSColor(red: CGFloat(x) / CGFloat(width), green: 0.5,
                                                                         blue: CGFloat(y) / CGFloat(height), alpha: 1), atX: x, y: y) } }
        return rep.representation(using: .png, properties: [:])!
    }

    /// Копии в `Attachments/` рядом с базой по записям таблицы `attachment`.
    private func attachmentCopies() throws -> [URL] {
        let attachments = library.databaseURL.deletingLastPathComponent().appendingPathComponent("Attachments", isDirectory: true)
        return try query("SELECT localPath FROM attachment WHERE localPath IS NOT NULL ORDER BY id").map { attachments.appendingPathComponent($0) }
    }

    private func attachmentCount() throws -> Int {
        try query("SELECT id FROM attachment WHERE localPath IS NOT NULL").count
    }

    private func query(_ sql: String) throws -> [String] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(library.databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw UITestLibrary.SQLiteFailure(message: "база не открылась")
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw UITestLibrary.SQLiteFailure(message: String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        var rows: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW { rows.append(String(cString: sqlite3_column_text(statement, 0))) }
        return rows
    }

    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }
}
