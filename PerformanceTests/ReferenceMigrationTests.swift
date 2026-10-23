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
        XCTAssertEqual(version, "v10", "через v7 до текущей схемы")
        XCTAssertTrue(backup, "Перед миграцией нет копии MyNotion.backup-v6.sqlite")
        XCTAssertLessThanOrEqual(seconds, Self.budgetSeconds, "Миграция эталона дольше 2 с")
    }

    /// Миграция эталона 003 (схема v8, `MyNotion-reference-library-v4`) → v9 (004, quickstart «Замеры бюджета»: ≤ 2 с, один раз):
    /// блоки пересоздаются с теми же rowid, появляются таблицы баз.
    func testReferenceLibraryMigratesToV9WithinBudget() throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyNotion-reference-library-v4", isDirectory: true).appendingPathComponent("MyNotion.sqlite")
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw XCTSkip("Нет эталона схемы v8: его создаёт замер сборки 003")
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
        let store = NotesStore(database: database, clock: HybridLogicalClock(deviceId: UUID()))
        let pages = try store.pageOutline().count
        database.close()
        // Эталон 003 мог остаться схемы v7 (до шага v8): копия — по той версии, с которой шла миграция.
        let backups = (try FileManager.default.contentsOfDirectory(atPath: folder.path)).filter { $0.contains(".backup-v") }
        let backup = !backups.isEmpty

        let summary = String(format: "Миграция эталона 003 → v9: %.2f с (с копией базы), страниц %d, схема %@, копия: %@",
                             seconds, pages, version ?? "—", backups.joined(separator: ", "))
        print(summary)
        add(XCTAttachment(string: summary))
        XCTAssertEqual(version, "v10")
        XCTAssertTrue(backup, "Перед миграцией нет копии базы")
        XCTAssertLessThanOrEqual(seconds, Self.budgetSeconds, "Миграция эталона дольше 2 с")
    }
}
