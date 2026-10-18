import Foundation
import NotesCore
import NotionImport
import PageSearch
import XCTest

/// Импорт выгрузки Notion на 1 000 страниц (T086, SC-010): целиком и не дольше минуты, а окно всё это время отвечает.
/// Импорт идёт в фоне, как в приложении; главный поток тем временем каждые 50 мс записывает правку страницы,
/// как автосохранение при наборе. Если импорт держит базу, эта запись ждёт, и окно замирает.
/// Сборка Release (research R13), база с индексом поиска, как в приложении.
final class NotionImportPerformanceTests: XCTestCase {
    static let budgetSeconds = 60.0
    /// Дольше этого запись правки ждать не должна: глаз замечает паузу набора.
    static let autosaveBudgetMilliseconds = 200.0

    func testThousandPagesImportWhileWindowResponds() throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("NotionImportPerformance-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let exportFolder = work.appendingPathComponent("Выгрузка", isDirectory: true)
        try SampleNotionExportGenerator().generate(into: exportFolder)

        let store = NotesStore(database: try AppDatabase.open(at: work.appendingPathComponent("MyNotion.sqlite")),
                               clock: HybridLogicalClock(deviceId: UUID()))
        store.addWriteHook(SearchIndexer())
        let openPage = try store.write { try $0.createPage(title: "Открытая страница") }
        var typedBlock = try XCTUnwrap(try store.pageContent(openPage.id)?.blocks.first)

        let finished = expectation(description: "Импорт закончен")
        nonisolated(unsafe) var outcome: Result<NotionImportReport, any Error>?
        let started = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            outcome = Result {
                let prepared = try NotionExportUnpacker().prepare(exportFolder)
                defer { prepared.discard() }
                return try NotionImporter(store: store).importExport(prepared)
            }
            finished.fulfill()
        }

        var autosaveMs: [Double] = []
        while outcome == nil {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            let before = Date()
            typedBlock.text = InlineText(typedBlock.text.string + "а")
            typedBlock = try store.write { try $0.updateBlock(typedBlock) }
            autosaveMs.append(Date().timeIntervalSince(before) * 1_000)
            if Date().timeIntervalSince(started) > Self.budgetSeconds * 2 { break }
        }
        wait(for: [finished], timeout: Self.budgetSeconds * 2)
        let elapsed = Date().timeIntervalSince(started)
        let report = try XCTUnwrap(outcome).get()

        let sorted = autosaveMs.sorted()
        let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        let summary = """
            Импорт \(report.pageCount) страниц, \(report.blockCount) блоков: \(String(format: "%.1f", elapsed)) с; \
            запись правки во время импорта: p95 \(String(format: "%.0f", p95)) мс, худшая \(String(format: "%.0f", sorted.last ?? 0)) мс, \
            \(sorted.count) записей
            """
        print(summary)
        add(XCTAttachment(string: summary))

        XCTAssertEqual(report.pageCount, SampleNotionExportGenerator.pageCount, "Перенесены не все страницы")
        XCTAssertEqual(try store.pageOutline().count, SampleNotionExportGenerator.pageCount + 2, "В базе не все страницы")
        XCTAssertLessThanOrEqual(elapsed, Self.budgetSeconds, "Импорт 1 000 страниц дольше минуты")
        XCTAssertLessThanOrEqual(sorted.last ?? 0, Self.autosaveBudgetMilliseconds, "Импорт держит базу: правка ждёт записи")
    }
}
