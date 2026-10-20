import Foundation
import NotesCore
import XCTest

/// Миграция эталона v6 → v7 (T024, quickstart «Замеры бюджета»: ≤ 2 с, один раз). Эталон схемы v6 — тот, что
/// оставила сборка 002 (`MyNotion-reference-library-v3`); его копия открывается текущей версией — с копией базы и миграцией.
final class ReferenceMigrationTests: XCTestCase {
    static let budgetSeconds = 2.0

    func testReferenceLibraryMigratesToV7WithinBudget() throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyNotion-reference-library-v3", isDirectory: true).appendingPathComponent("MyNotion.sqlite")
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw XCTSkip("Нет эталона схемы v6: его создаёт замер сборки 002")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MyNotion-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let copy = folder.appendingPathComponent("MyNotion.sqlite")
        try FileManager.default.copyItem(at: source, to: copy)

        let started = Date()
        let database = try AppDatabase.open(at: copy)
        let seconds = Date().timeIntervalSince(started)
        let version = try database.appliedSchemaVersion()
        let pages = try NotesStore(database: database, clock: HybridLogicalClock(deviceId: UUID())).pageOutline().count
        database.close()
        let backup = FileManager.default.fileExists(atPath: AppDatabase.backupURL(for: copy, version: "v6").path)

        let summary = String(format: "Миграция эталона v6 → v7: %.2f с (с копией базы), страниц %d, схема %@, копия v6 %@",
                             seconds, pages, version ?? "—", backup ? "есть" : "нет")
        print(summary)
        add(XCTAttachment(string: summary))
        XCTAssertEqual(version, "v7")
        XCTAssertTrue(backup, "Перед миграцией нет копии MyNotion.backup-v6.sqlite")
        XCTAssertLessThanOrEqual(seconds, Self.budgetSeconds, "Миграция эталона дольше 2 с")
    }
}
