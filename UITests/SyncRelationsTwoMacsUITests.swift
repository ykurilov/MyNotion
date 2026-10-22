import AppKit
import SQLite3
import XCTest

/// Связи и сводки на двух Mac вживую (US4, T094, quickstart.md «Синхронизация», шаги 1–2): первый Mac — «Задачи» ↔
/// «Проекты» с двусторонней связью и сводкой «Часов»; второй после подключения видит те же связи, а сводку считает сам
/// (на сервер она не уходит) и получает то же число. Правка часов на первом — сводка второго пересчитана, задержка
/// пишется в итог. Встречные правки связей — `RelationLinkMergeTests`. Запуск:
/// `scripts/imac/sync-live-check.sh --test SyncRelationsTwoMacsUITests`.
final class SyncRelationsTwoMacsUITests: XCTestCase {
    private let live = URL(fileURLWithPath: "/tmp/mn-sync-live", isDirectory: true)

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard FileManager.default.fileExists(atPath: live.appendingPathComponent("server-url").path) else {
            throw XCTSkip("Нет локального сервера: запустите scripts/imac/sync-live-check.sh --test SyncRelationsTwoMacsUITests")
        }
    }

    @MainActor
    func testRelationsAndRollupsArriveOnSecondMac() throws {
        let server = try String(contentsOf: live.appendingPathComponent("server-url"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let code = live.appendingPathComponent("join-code")
        try? FileManager.default.removeItem(at: code)
        let databaseA = live.appendingPathComponent("rel-a/MyNotion.sqlite"), databaseB = live.appendingPathComponent("rel-b/MyNotion.sqlite")

        let first = XCUIApplication()
        first.launchArguments = ["--database", databaseA.path, "--relations-demo-linked", "--sync-server", server, "--sync-device-name", "Mac A",
                                 "--sync-log", live.appendingPathComponent("mac-a.log").path,
                                 "--sync-connect-token-file", live.appendingPathComponent("token").path, "--sync-write-join-code", code.path]
        first.launch()
        addTeardownBlock { @MainActor in if first.state != .notRunning { first.terminate() } }
        let grid = first.descendants(matching: .any).matching(identifier: "database-grid").element(boundBy: 0)
        XCTAssertTrue(grid.waitForExistence(timeout: 30), "«Задачи» не открылись")
        XCTAssertTrue(waitFor(timeout: 20) { (try? self.rollup(databaseA, "Дом")) == "5" }, "Сводка первого Mac: \(String(describing: try? rollup(databaseA, "Дом")))")
        XCTAssertTrue(waitFor(timeout: 20) { FileManager.default.fileExists(atPath: code.path) }, "Первый Mac не выдал код подключения")

        let second = XCUIApplication(url: live.appendingPathComponent("MyNotionB.app"))
        second.launchArguments = ["--database", databaseB.path, "--sync-server", server, "--sync-device-name", "Mac B",
                                  "--sync-log", live.appendingPathComponent("mac-b.log").path, "--sync-join-code-file", code.path]
        let joined = Date()
        second.launch()
        addTeardownBlock { @MainActor in if second.state != .notRunning { second.terminate() } }

        // Шаг 1: схема, связи и итог сводки — на втором Mac (сводку он считает сам).
        XCTAssertTrue(waitFor(timeout: 30) { (try? self.links(databaseB)) == 3 }, "Связи не дошли: \(String(describing: try? links(databaseB)))")
        XCTAssertTrue(waitFor(timeout: 30) { (try? self.rollup(databaseB, "Дом")) == "5" && (try? self.rollup(databaseB, "Работа")) == "4" },
                      "Сводка второго Mac: \(String(describing: try? rollup(databaseB, "Дом"))), \(String(describing: try? rollup(databaseB, "Работа")))")
        let arrival = Date().timeIntervalSince(joined)

        // Открытая таблица второго клиента, а не только совпадение SQLite на диске.
        let projects = second.outlines["page-tree"].outlineRows.containing(NSPredicate(format: "value == %@", "Проекты")).firstMatch
        XCTAssertTrue(projects.waitForExistence(timeout: 10), "Нет базы «Проекты» на втором Mac")
        second.activate()
        projects.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        let secondGrid = second.descendants(matching: .any).matching(identifier: "database-grid").element(boundBy: 0)
        XCTAssertTrue(secondGrid.waitForExistence(timeout: 10), "«Проекты» не открылись на втором Mac")

        // Шаг 2: правка часов «Позвонить» на первом Mac — сводка «Дома» на втором пересчитана.
        first.activate()
        grid.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 280 + 60, dy: 33 + 33 / 2)).click()
        XCTAssertTrue(first.descendants(matching: .any)["database-cell-editor"].waitForExistence(timeout: 5), "Нет правки числа на первом Mac")
        first.typeKey("a", modifierFlags: .command)
        first.typeText("10")
        first.typeKey(.return, modifierFlags: [])
        let edited = Date()
        XCTAssertTrue(waitFor(timeout: 10) { (try? self.rollup(databaseA, "Дом")) == "13" }, "Правка не записалась на первом Mac")
        XCTAssertTrue(waitFor(timeout: 20) { (try? self.rollup(databaseB, "Дом")) == "13" },
                      "Сводка второго Mac после правки: \(String(describing: try? rollup(databaseB, "Дом")))")
        let delay = Date().timeIntervalSince(edited)

        // Шаг 3 связей: добавление с обоих клиентов, в том числе с ответной стороны.
        first.activate()
        grid.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 540, dy: 49.5)).click()
        XCTAssertTrue(first.descendants(matching: .any)["relation-picker-search"].waitForExistence(timeout: 5))
        first.typeText("Работа")
        first.typeKey(.return, modifierFlags: [])
        first.typeKey(.escape, modifierFlags: [])
        second.activate()
        secondGrid.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 340, dy: 49.5)).click()
        XCTAssertTrue(second.descendants(matching: .any)["relation-picker-search"].waitForExistence(timeout: 5))
        second.typeText("Сдать отчёт")
        second.typeKey(.return, modifierFlags: [])
        second.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitFor(timeout: 20) {
            [databaseA, databaseB].allSatisfy {
                (try? self.links($0)) == 5 && (try? self.rollup($0, "Дом")) == "17" && (try? self.rollup($0, "Работа")) == "14"
            }
        }, "Связи с двух сторон или их сводки не сошлись")
        let summary = String(format: "Связи на двух Mac: всё со сводкой дошло за %.1f с после подключения; правка часов → сводка второго Mac за %.1f с", arrival, delay)
        print(summary)
        add(XCTAttachment(string: summary))
        for (app, name) in [(first, "mac-a"), (second, "mac-b")] {
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "relations-\(name)"
            shot.lifetime = .keepAlways
            add(shot)
        }
    }

    private func waitFor(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return condition()
    }

    private func query(_ url: URL, _ sql: String, _ arguments: [String]) throws -> [[String]] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw Failure.open }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw Failure.sql(String(cString: sqlite3_errmsg(database))) }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, argument) in arguments.enumerated() { sqlite3_bind_text(statement, Int32(index + 1), argument, -1, transient) }
        var rows: [[String]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append((0..<sqlite3_column_count(statement)).map { sqlite3_column_text(statement, $0).map { String(cString: $0) } ?? "" })
        }
        return rows
    }

    private enum Failure: Error { case open, sql(String) }

    private func links(_ url: URL) throws -> Int {
        Int(try query(url, "SELECT count(*) FROM db_relation_link WHERE isPresent = 1", []).first?.first ?? "") ?? 0
    }

    /// Итог сводки «Часов» у строки «Проектов».
    private func rollup(_ url: URL, _ project: String) throws -> String? {
        try query(url, """
            SELECT c.value FROM db_computed c JOIN db_property p ON p.id = c.propertyId AND p.name = 'Часов'
            JOIN page r ON r.id = c.rowId AND r.title = ? AND r.trashedAt IS NULL
            """, [project]).first?.first
    }
}
