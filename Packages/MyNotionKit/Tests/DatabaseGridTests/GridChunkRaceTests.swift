import Foundation
import Testing
@testable import DatabaseGrid
@testable import Databases
@testable import NotesCore

/// Порция строк, прочитанная фоном (T085), не затирает правку, сделанную после начала её чтения.
@MainActor
@Suite("Сетка: порция фоном и правка ячейки")
struct GridChunkRaceTests {
    @Test("Правка названия, пока порция читается фоном: после прихода порции видно новое название")
    func editDuringBackgroundReadSurvives() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("chunk-race-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = NotesStore(database: try AppDatabase.open(at: folder.appendingPathComponent("MyNotion.sqlite")), clock: HybridLogicalClock(deviceId: UUID()))
        let operations = DatabaseOperations(store: store)
        let base = try operations.createDatabase(in: nil, isInline: false, title: "Задачи")
        for index in 0..<30 { try operations.addRow(to: base.databaseId, in: base.viewId, title: "Строка \(index)") }
        let opened = try #require(DatabaseTableController(store: store, operations: operations, databaseId: base.databaseId)).content
        let content = GridContent(store: store, catalog: opened.catalog, columns: opened.columns, rowIds: opened.rowIds)
        let title = try #require(content.columns.firstIndex { $0.property.kind == .title })

        let (readDone, readDoneSignal) = AsyncStream<Void>.makeStream()
        let (release, releaseSignal) = AsyncStream<Void>.makeStream()
        content.afterBackgroundRead = {
            readDoneSignal.yield()
            for await _ in release { break }
        }
        let (loaded, loadedSignal) = AsyncStream<Void>.makeStream()
        content.onRowsLoaded = { _ in loadedSignal.yield() }

        // Первый экран нарисован поштучно, порция читается фоном и уже прочитана — со старым названием.
        content.prepareRows(0..<10)
        content.prefetch(around: 0..<10)
        for await _ in readDone { break }

        try operations.setTitle(of: content.rowIds[1], to: "Новое")
        content.reloadRow(1)          // прочитанная поштучно строка
        try operations.setTitle(of: content.rowIds[20], to: "Тоже новое")
        content.reloadRow(20)         // ещё не прочитанная строка той же порции
        #expect(content.row(at: 1)?.cells[title] == .text("Новое"))

        releaseSignal.yield()
        for await _ in loaded { break }
        #expect(content.row(at: 1)?.cells[title] == .text("Новое"))
        #expect(content.row(at: 20)?.cells[title] == .text("Тоже новое"))
    }
}
