import AppKit
import SQLite3
import XCTest

/// Два Mac вживую (quickstart.md, US5): два экземпляра MyNotion со своими базами против локального сервера синхронизации.
/// Первый подключается токеном устройства и пишет код подключения, второй подключается этим кодом.
/// Правка в открытой странице одного появляется в открытой странице другого не позже чем через 10 с (SC-007).
/// Запускается сценарием `scripts/imac/sync-live-check.sh` (запасной — `scripts/vm/…`): он поднимает сервер на iMac и кладёт
/// в `/tmp/mn-sync-live` адрес сервера, токен первого устройства и копию приложения со своим bundle id.
final class SyncTwoMacsUITests: XCTestCase {
    private let live = URL(fileURLWithPath: "/tmp/mn-sync-live", isDirectory: true)

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard FileManager.default.fileExists(atPath: live.appendingPathComponent("server-url").path) else {
            throw XCTSkip("Нет локального сервера: запустите scripts/imac/sync-live-check.sh")
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
                                 "--versions-quick", "--sync-server", server, "--sync-device-name", "Mac A", "--sync-log", live.appendingPathComponent("mac-a.log").path,
                                 "--sync-connect-token-file", live.appendingPathComponent("token").path,
                                 "--sync-write-join-code", code.path]
        first.launch()
        addTeardownBlock { @MainActor in if first.state != .notRunning { first.terminate() } }
        XCTAssertTrue(first.pageBody.waitForExistence(timeout: 15))
        XCTAssertTrue(waitFor(timeout: 20) { FileManager.default.fileExists(atPath: code.path) }, "Первый Mac не выдал код подключения")
        XCTAssertTrue(first.syncBadge.waitForExistence(timeout: 10), "Нет значка синхронизации")

        let second = XCUIApplication(url: live.appendingPathComponent("MyNotionB.app"))
        second.launchArguments = ["--database", live.appendingPathComponent("mac-b/MyNotion.sqlite").path, "--versions-quick",
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

        // Живая проверка 003 (quickstart.md, «Живая проверка на двух Mac»): пять шагов на тех же двух Mac.
        try favoritesOrderArrives(first, second, textDelay: firstDelay)
        try coverPictureArrivesAfterPlaceholder(first, second)
        try concurrentFavoriteReordersConverge(first, second)
        try restoredVersionArrivesWithAuthor(first, second)
        try movedBlocksArrive(first, second)
    }

    // MARK: Шаги 003

    /// Шаг 1: звезда у трёх страниц на Mac A и перестановка — на Mac B тот же порядок.
    @MainActor
    private func favoritesOrderArrives(_ first: XCUIApplication, _ second: XCUIApplication, textDelay: TimeInterval) throws {
        first.activate()
        for title in ["Альфа", "Бета", "Гамма"] {
            first.createPage(titled: title)
            waitForStar(first, page: title, label: "Добавить в избранное")
            first.buttons["page-favorite-star"].click()
        }
        XCTAssertTrue(waitForFavorites(first, ["Альфа", "Бета", "Гамма"]))
        XCTAssertTrue(waitForFavorites(second, ["Альфа", "Бета", "Гамма"], timeout: 20), "Звёзды не дошли до Mac B")

        first.activate()
        favoriteMiddle(first, "Гамма").press(forDuration: 0.5, thenDragTo: favoriteMiddle(first, "Альфа"))
        XCTAssertTrue(waitForFavorites(first, ["Гамма", "Альфа", "Бета"]))
        let moved = Date()
        let arrived = waitForFavorites(second, ["Гамма", "Альфа", "Бета"], timeout: 10)
        let delay = Date().timeIntervalSince(moved)
        saveScreenshots(first, second, suffix: "-1-favorites")
        XCTAssertTrue(arrived, "Порядок избранного не дошёл до Mac B за 10 с")
        print("Задержка шаг 1 (порядок избранного A→B): \(Self.seconds(delay)) с; текст A→B: \(Self.seconds(textDelay)) с")
    }

    /// Шаг 2: обложка-картинка 20 МБ на Mac A — на Mac B сначала заглушка, затем картинка.
    @MainActor
    private func coverPictureArrivesAfterPlaceholder(_ first: XCUIApplication, _ second: XCUIApplication) throws {
        let name = "cover-20mb.png"
        let picture = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let bytes = Self.noisyPNG(width: 3000, height: 2250)
        try bytes.write(to: picture)
        first.activate()
        first.createPage(titled: "Обложка")
        open(second, "Обложка")

        // Сначала обложка из галереи («Добавить обложку»), затем «Сменить обложку» → «Загрузить» → свой файл.
        first.activate()
        let cover = first.descendants(matching: .any)["page-cover"]
        let addCover = first.descendants(matching: .any)["add-page-cover"]
        first.pageTitle.hover()
        XCTAssertTrue(addCover.waitForExistence(timeout: 5), "«Добавить обложку» не появилась")
        addCover.click()
        XCTAssertTrue(cover.waitForExistence(timeout: 5), "Обложка не поставилась")
        cover.hover()
        let change = first.descendants(matching: .any)["change-page-cover"]
        XCTAssertTrue(change.waitForExistence(timeout: 5), "«Сменить обложку» не появилась")
        change.click()
        let uploadTab = first.descendants(matching: .any)["cover-tab-upload"]
        XCTAssertTrue(uploadTab.waitForExistence(timeout: 5), "Окно «Сменить обложку» не открылось")
        uploadTab.click()
        first.descendants(matching: .any)["cover-upload-file"].click()
        let sheet = first.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "Окно выбора файла не открылось")
        first.typeKey("g", modifierFlags: [.command, .shift])
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        first.typeText(picture.path)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        first.typeKey(.return, modifierFlags: [])
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        let upload = sheet.buttons["Загрузить"]
        if upload.waitForExistence(timeout: 3), upload.isEnabled { upload.click() } else { first.typeKey(.return, modifierFlags: []) }
        XCTAssertTrue(waitFor(timeout: 10) { !sheet.exists }, "Окно выбора файла не закрылось")
        let chosen = Date()
        XCTAssertTrue(waitFor(timeout: 10) { cover.value as? String == name }, "Своя картинка не стала обложкой на Mac A")

        // Mac B: обложка-файл пришла раньше самого файла — заглушка; файл с теми же байтами — картинка.
        // Мышь — над текстом Mac B: кнопки обложки под мышью не попадут в снимок заглушки.
        second.activate()
        second.pageBody.hover()
        let otherCover = second.descendants(matching: .any)["page-cover"]
        XCTAssertTrue(waitFor(timeout: 20) { otherCover.exists && otherCover.value as? String == name }, "Обложка не дошла до Mac B")
        let coverArrived = Date().timeIntervalSince(chosen)
        var placeholderSeen = false
        let pictureShown = waitFor(timeout: 120) {
            let fileArrived = self.attachmentSize(of: "mac-b", named: name) == bytes.count
            let isPlain = Self.isPlain(otherCover.screenshot().image)
            if isPlain, !fileArrived, !placeholderSeen {
                placeholderSeen = true
                self.saveScreenshot(second, name: "mac-b-2-cover-placeholder")
            }
            return fileArrived && !isPlain
        }
        let pictureDelay = Date().timeIntervalSince(chosen)
        saveScreenshots(first, second, suffix: "-2-cover")
        XCTAssertTrue(pictureShown, "Картинка обложки не показалась на Mac B за 120 с")
        XCTAssertEqual(try attachmentCopy(of: "mac-b", named: name), bytes, "На Mac B другие байты обложки")
        XCTAssertTrue(placeholderSeen, "На Mac B не было заглушки до прихода файла")
        print("Задержка шаг 2 (обложка \(bytes.count / 1_000_000) МБ): заглушка на Mac B через \(Self.seconds(coverArrived)) с, картинка через \(Self.seconds(pictureDelay)) с")
    }

    /// Шаг 3: оба Mac переставляют избранное по-разному, не видя правки друг друга, — порядок сходится, все три строки на месте.
    /// Встречность — без служебных флагов: свой сервер сценария на время двух перестановок заморожен (SIGSTOP), правки ждут
    /// отправки на обоих Mac и уходят разом после SIGCONT.
    @MainActor
    private func concurrentFavoriteReordersConverge(_ first: XCUIApplication, _ second: XCUIApplication) throws {
        let all: Set = ["Альфа", "Бета", "Гамма"]
        let initial = ["Гамма", "Альфа", "Бета"]
        XCTAssertTrue(waitForFavorites(first, initial) && waitForFavorites(second, initial))
        let pidText = try String(contentsOf: live.appendingPathComponent("server.pid"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let server = try XCTUnwrap(pid_t(pidText), "Нет номера процесса сервера: «\(pidText)»")
        XCTAssertEqual(kill(server, SIGSTOP), 0, "Сервер не заморозился: errno \(errno)")
        var isFrozen = true
        defer { if isFrozen { kill(server, SIGCONT) } }

        first.activate()
        favoriteMiddle(first, "Бета").press(forDuration: 0.3, thenDragTo: favoriteMiddle(first, "Гамма"))
        XCTAssertTrue(waitForFavorites(first, ["Бета", "Гамма", "Альфа"]))
        second.activate()
        XCTAssertEqual(favoriteTitles(second), initial, "Правка Mac A дошла до Mac B при замороженном сервере")
        favoriteMiddle(second, "Альфа").press(forDuration: 0.3, thenDragTo: favoriteMiddle(second, "Гамма"))
        XCTAssertTrue(waitForFavorites(second, ["Альфа", "Гамма", "Бета"]))
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let firstAlone = favoriteTitles(first), secondAlone = favoriteTitles(second)

        XCTAssertEqual(kill(server, SIGCONT), 0)
        isFrozen = false
        let released = Date()
        let converged = waitFor(timeout: 20) {
            let a = self.favoriteTitles(first), b = self.favoriteTitles(second)
            return a == b && Set(a) == all && a.count == 3
        }
        let delay = Date().timeIntervalSince(released)
        // Порядок держится: через 2 с всё ещё одинаковый и полный.
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        let a = favoriteTitles(first), b = favoriteTitles(second)
        saveScreenshots(first, second, suffix: "-3-concurrent")
        XCTAssertTrue(converged && a == b && Set(a) == all && a.count == 3, "Порядок не сошёлся: Mac A \(a), Mac B \(b)")
        XCTAssertTrue(waitFor(timeout: 15) { first.syncBadge.label == "Синхронизировано" && second.syncBadge.label == "Синхронизировано" },
                      "Значок: \(first.syncBadge.label) / \(second.syncBadge.label)")
        print("Задержка шаг 3 (встречные перестановки): сошлось через \(Self.seconds(delay)) с после размораживания сервера; Mac A \(firstAlone), Mac B \(secondAlone) → итог \(a)")
    }

    /// Шаг 4: Mac A восстанавливает прошлую версию страницы — Mac B видит ту же страницу и новую версию с автором «Mac A».
    @MainActor
    private func restoredVersionArrivesWithAuthor(_ first: XCUIApplication, _ second: XCUIApplication) throws {
        first.activate()
        open(first, "Альфа")
        first.pageBody.click()
        first.typeText("Первая редакция")
        RunLoop.current.run(until: Date().addingTimeInterval(3.5))
        first.typeKey(.downArrow, modifierFlags: .command)
        first.typeText(" и вторая")
        RunLoop.current.run(until: Date().addingTimeInterval(3.5))
        open(second, "Альфа")
        XCTAssertTrue(waitFor(timeout: 10) { second.pageBodyText.contains("Первая редакция и вторая") }, "Правка «Альфы» не дошла до Mac B")
        // Версии Mac B от правок Mac A записаны — дальше считаем только новые.
        XCTAssertTrue(waitFor(timeout: 15) { (try? self.dueVersionMarks(of: "mac-b", page: "Альфа")) == 0 }, "Mac B не записал версию правки")
        let versionsBefore = try versionCount(of: "mac-b", page: "Альфа", author: "Mac A")

        first.activate()
        openHistory(first)
        let rows = first.descendants(matching: .any).matching(identifier: "version-row")
        XCTAssertTrue(waitFor(timeout: 8) { rows.count >= 2 }, "У «Альфы» на Mac A меньше двух версий: \(rows.count)")
        rows.element(boundBy: 1).coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).click()
        let restore = first.descendants(matching: .any)["version-begin-restore"]
        XCTAssertTrue(waitFor(timeout: 8) { restore.isEnabled }, "«Восстановить» не включилась у прошлой версии")
        restore.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        let confirm = first.descendants(matching: .any)["version-restore-confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Окно «Что будет восстановлено» не открылось")
        confirm.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(first.descendants(matching: .any)["version-restored-banner"].waitForExistence(timeout: 5), "Нет полосы «Страница восстановлена»")
        let restored = Date()
        XCTAssertTrue(waitFor(timeout: 8) { !first.pageBodyText.contains("и вторая") }, "Mac A: страница не стала как в прошлой версии")
        let expected = first.pageBodyText

        let same = waitFor(timeout: 10) { second.pageBodyText == expected }
        let delay = Date().timeIntervalSince(restored)
        XCTAssertTrue(same, "Mac B: «\(second.pageBodyText)», на Mac A «\(expected)»")
        XCTAssertTrue(waitFor(timeout: 15) { ((try? self.versionCount(of: "mac-b", page: "Альфа", author: "Mac A")) ?? 0) > versionsBefore },
                      "В истории Mac B нет новой версии с автором «Mac A»")
        let versionDelay = Date().timeIntervalSince(restored)
        XCTAssertEqual(try latestVersionAuthor(of: "mac-b", page: "Альфа"), "Mac A")

        second.activate()
        openHistory(second)
        let otherRows = second.descendants(matching: .any).matching(identifier: "version-row")
        XCTAssertTrue(otherRows.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(otherRows.firstMatch.staticTexts["Mac A"].exists || second.staticTexts["Mac A"].exists, "В истории Mac B не видно автора «Mac A»")
        saveScreenshots(first, second, suffix: "-4-restore")
        second.typeKey(.escape, modifierFlags: [])
        print("Задержка шаг 4 (восстановление версии A→B): страница \(Self.seconds(delay)) с, версия с автором «Mac A» \(Self.seconds(versionDelay)) с")
    }

    /// Шаг 5: Mac A переносит блоки на другую страницу (⇧⌘P) — на Mac B блоки у цели и пропали у источника.
    @MainActor
    private func movedBlocksArrive(_ first: XCUIApplication, _ second: XCUIApplication) throws {
        first.activate()
        first.createPage(titled: "Перенос: цель")
        first.typeText("Первый абзац цели")
        first.createPage(titled: "Перенос: исходная")
        first.typeText("Начало\nБлок 1\nБлок 2\nКонец")
        open(second, "Перенос: исходная")
        XCTAssertTrue(waitFor(timeout: 10) { second.pageBodyText == "Начало\nБлок 1\nБлок 2\nКонец" }, "Mac B: «\(second.pageBodyText)»")

        first.activate()
        open(first, "Перенос: исходная")
        // Курсор в «Начало», ↓ на «Блок 1», Esc — выделен блок, ⇧↓ — и «Блок 2».
        first.pageBody.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 40, dy: 10)).click()
        first.typeKey(.downArrow, modifierFlags: [])
        first.typeKey(.escape, modifierFlags: [])
        first.typeKey(.downArrow, modifierFlags: .shift)
        first.typeKey("p", modifierFlags: [.command, .shift])
        let field = first.descendants(matching: .any)["page-picker-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "⇧⌘P не открыл «Переместить в…»")
        first.typeText("Перенос: цель")
        let target = first.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'page-picker-row' AND label == %@", "Перенос: цель")).firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 5), "Поиск не нашёл цель")
        target.click()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), "Окно выбора не закрылось")
        XCTAssertTrue(waitFor(timeout: 5) { first.pageBodyText == "Начало\nКонец" }, "Mac A: блоки остались: «\(first.pageBodyText)»")
        let moved = Date()

        let gone = waitFor(timeout: 10) { second.pageBodyText == "Начало\nКонец" }
        let delay = Date().timeIntervalSince(moved)
        XCTAssertTrue(gone, "Mac B: на старом месте «\(second.pageBodyText)»")
        XCTAssertTrue(waitFor(timeout: 10) { (try? self.blockTexts(of: "mac-b", page: "Перенос: цель")) == ["Первый абзац цели", "Блок 1", "Блок 2"] },
                      "Mac B, цель: \((try? blockTexts(of: "mac-b", page: "Перенос: цель")) ?? [])")
        XCTAssertEqual(try blockTexts(of: "mac-b", page: "Перенос: исходная"), ["Начало", "Конец"])
        open(second, "Перенос: цель")
        XCTAssertTrue(waitFor(timeout: 5) { second.pageBodyText == "Первый абзац цели\nБлок 1\nБлок 2" }, "Mac B, цель на экране: «\(second.pageBodyText)»")
        saveScreenshots(first, second, suffix: "-5-move")
        print("Задержка шаг 5 (перенос блоков A→B): \(Self.seconds(delay)) с")
    }

    // MARK: Помощники 003

    /// Открыть страницу щелчком по середине строки панели; повтор, пока не открылась.
    @MainActor
    private func open(_ app: XCUIApplication, _ title: String) {
        app.activate()
        let row = app.outlines["page-tree"].outlineRows.containing(NSPredicate(format: "value == %@", title)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "В дереве нет «\(title)»")
        for _ in 0..<3 where app.pageTitle.value as? String != title {
            row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
            _ = waitFor(timeout: 3) { app.pageTitle.value as? String == title }
        }
        XCTAssertEqual(app.pageTitle.value as? String, title)
    }

    /// Ждёт, пока открыта `page` и ☆ показывает нужное состояние (как в FavoritesRecentsTests).
    @MainActor
    private func waitForStar(_ app: XCUIApplication, page: String, label: String) {
        let star = app.buttons["page-favorite-star"]
        XCTAssertTrue(waitFor(timeout: 5) { app.pageTitle.value as? String == page && star.exists && star.label == label },
                      "Ждали «\(page)» с ☆ «\(label)», есть «\(app.pageTitle.value as? String ?? "nil")» и «\(star.label)»")
    }

    @MainActor
    private func favoriteMiddle(_ app: XCUIApplication, _ title: String) -> XCUICoordinate {
        app.outlines["favorites-tree"].outlineRows.containing(NSPredicate(format: "value == %@", title)).firstMatch
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    }

    @MainActor
    private func favoriteTitles(_ app: XCUIApplication) -> [String] {
        app.outlines["favorites-tree"].descendants(matching: .any).matching(identifier: "favorites-row-title")
            .allElementsBoundByIndex.compactMap { $0.value as? String }
    }

    @MainActor
    private func waitForFavorites(_ app: XCUIApplication, _ expected: [String], timeout: TimeInterval = 5) -> Bool {
        waitFor(timeout: timeout) { self.favoriteTitles(app) == expected }
    }

    @MainActor
    private func openHistory(_ app: XCUIApplication) {
        let menu = app.descendants(matching: .any)["page-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.click()
        let item = app.descendants(matching: .any)["page-menu-versionHistory"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "В меню нет «История версий»")
        item.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(app.descendants(matching: .any)["version-history"].waitForExistence(timeout: 5), "История не открылась")
    }

    /// Обложка без картинки — ровная заливка: по сетке точек цвет почти не меняется.
    private static func isPlain(_ image: NSImage) -> Bool {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return true }
        let rep = NSBitmapImageRep(cgImage: cg)
        var lowest = [255, 255, 255], highest = [0, 0, 0]
        for i in 1..<10 {
            for j in 1..<5 {
                guard let color = rep.colorAt(x: rep.pixelsWide * i / 10, y: rep.pixelsHigh * j / 5)?.usingColorSpace(.deviceRGB) else { continue }
                for (k, c) in [color.redComponent, color.greenComponent, color.blueComponent].enumerated() {
                    lowest[k] = min(lowest[k], Int(c * 255)); highest[k] = max(highest[k], Int(c * 255))
                }
            }
        }
        return zip(lowest, highest).allSatisfy { $1 - $0 < 16 }
    }

    /// Картинка с переходом цвета слева направо и шумом: шум не сжимается, 3000 × 2250 — около 20 МБ.
    private static func noisyPNG(width: Int, height: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32)!
        let pixels = rep.bitmapData!
        var random = SystemRandomNumberGenerator()
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4, t = Double(x) / Double(width), noise = random.next() as UInt64
                pixels[i] = UInt8(min(255, 230 * (1 - t) + Double(noise & 63)))
                pixels[i + 1] = UInt8(min(255, 120 + Double((noise >> 8) & 63)))
                pixels[i + 2] = UInt8(min(255, 200 * t + Double((noise >> 16) & 63)))
                pixels[i + 3] = 255
            }
        }
        return rep.representation(using: .png, properties: [:])!
    }

    private static func seconds(_ interval: TimeInterval) -> String { String(format: "%.2f", interval) }

    /// Размер копии файла на «Mac»; `nil` — ещё нет.
    private func attachmentSize(of mac: String, named name: String) -> Int? {
        guard let path = try? query(mac, "SELECT localPath FROM attachment WHERE localPath LIKE ?", ["%/" + name]).first?.first else { return nil }
        let url = live.appendingPathComponent(mac).appendingPathComponent("Attachments").appendingPathComponent(path)
        return (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
    }

    /// Тексты блоков страницы в базе «Mac» в порядке страницы.
    private func blockTexts(of mac: String, page title: String) throws -> [String] {
        try query(mac, """
            SELECT block.text FROM block JOIN page ON page.id = block.pageId
            WHERE page.title = ? AND page.trashedAt IS NULL AND block.isDeleted = 0 ORDER BY block.sortKey
            """, [title]).map { $0[0] }
    }

    /// Ключ страницы в таблицах версий: UUID строкой в нижнем регистре.
    private static let versionPageKey = """
        (SELECT lower(CASE typeof(id) WHEN 'blob' THEN substr(hex(id),1,8)||'-'||substr(hex(id),9,4)||'-'||substr(hex(id),13,4)||'-'||substr(hex(id),17,4)||'-'||substr(hex(id),21)
         ELSE id END) FROM page WHERE title = ? AND trashedAt IS NULL)
        """

    private func versionCount(of mac: String, page title: String, author: String) throws -> Int {
        Int(try query(mac, "SELECT COUNT(*) FROM page_version WHERE deviceName = ? AND pageId = \(Self.versionPageKey)", [author, title]).first?.first ?? "0") ?? 0
    }

    private func latestVersionAuthor(of mac: String, page title: String) throws -> String? {
        try query(mac, "SELECT deviceName FROM page_version WHERE pageId = \(Self.versionPageKey) ORDER BY createdAt DESC, id DESC LIMIT 1", [title]).first?.first
    }

    private func dueVersionMarks(of mac: String, page title: String) throws -> Int {
        Int(try query(mac, "SELECT COUNT(*) FROM page_version_due WHERE pageId = \(Self.versionPageKey)", [title]).first?.first ?? "0") ?? 0
    }

    /// Строки запроса к базе «Mac» (только чтение), значения — строками.
    private func query(_ mac: String, _ sql: String, _ arguments: [String]) throws -> [[String]] {
        let path = live.appendingPathComponent(mac).appendingPathComponent("MyNotion.sqlite").path
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw NSError(domain: "SQLite", code: 1) }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw NSError(domain: "SQLite", code: 2, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(database))])
        }
        defer { sqlite3_finalize(statement) }
        for (index, argument) in arguments.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), argument, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        var rows: [[String]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append((0..<sqlite3_column_count(statement)).map { sqlite3_column_text(statement, $0).map { String(cString: $0) } ?? "" })
        }
        return rows
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
    @MainActor
    private func saveScreenshots(_ first: XCUIApplication, _ second: XCUIApplication, suffix: String = "") {
        // Окна лежат друг на друге: снимок — после того, как окно вышло вперёд.
        for (name, app) in [("mac-a", first), ("mac-b", second)] {
            app.activate()
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            saveScreenshot(app, name: name + suffix)
        }
    }

    @MainActor
    private func saveScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
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
