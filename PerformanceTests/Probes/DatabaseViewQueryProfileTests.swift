import Databases
import Foundation
import NotesCore
import XCTest

/// Только диагностика собственного пути группировки без окна и рисования. Не подтверждает бюджет открытия вида.
@MainActor
final class DatabaseViewQueryProfileTests: XCTestCase {
    func testProfileWorkViewReadsWithoutWindows() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MYNOTION_US3_QUERY_PROFILE"] == "1", "Запускается адресным profile-скриптом")
        let library = try DatabaseProbeLibrary.copy()
        defer { library.store.database.close(); try? FileManager.default.removeItem(at: library.folder) }
        let count = try library.store.write { tx in
            try tx.fetchTexts(sql: "SELECT COUNT(*) FROM page WHERE parentId = ? AND trashedAt IS NULL AND isTemplate = 0",
                              arguments: [.text(library.sample.tasksId.uuidString.lowercased())]).first.flatMap(Int.init)
        }
        XCTAssertEqual(count, 10_000)
        let first = try XCTUnwrap(try ViewQuery.present(library.sample.workViewId, in: library.store))
        XCTAssertNotNil(first.groups)
        let statusId = try XCTUnwrap(library.sample.taskProperties["Статус"])
        XCTAssertEqual(first.view.groupSettings?.propertyId, statusId)
        let statusValues = try library.store.write { tx in
            try tx.fetchTexts(sql: "SELECT COUNT(*) FROM db_cell WHERE propertyId = ? AND sortText IS NOT NULL",
                              arguments: [.text(statusId.uuidString.lowercased())]).first.flatMap(Int.init)
        }
        XCTAssertEqual(statusValues, 10_000)
        print("US3 QUERY PROFILE READY: tasks=\(count ?? 0), status values=\(statusValues ?? 0), matched=\(first.rowIds.count), groups=\(first.groups?.count ?? 0); без окон")
        fflush(nil)
        let until = Date().addingTimeInterval(14)
        var rounds = 0
        repeat {
            try autoreleasepool {
                let result = try XCTUnwrap(try ViewQuery.present(library.sample.workViewId, in: library.store))
                XCTAssertEqual(result.rowIds, first.rowIds)
                XCTAssertEqual(result.groups, first.groups)
            }
            rounds += 1
        } while Date() < until
        print("US3 QUERY PROFILE DONE: \(rounds) повторов; времена не приёмочные")
    }
}
