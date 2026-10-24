import Foundation
import NotesCore
import Synchronization
import Testing
@testable import MarkdownExport
@testable import NotionImport

/// Замеры SC-308 (T064): импорт выгрузки Notion с базой на 10 000 строк — ≤ 60 с, правки во время импорта пишутся
/// с отзывом ≤ 100 мс; выгрузка «Задач» эталона — ≤ 10 с. Долгие: включаются `MYNOTION_PERF=1`.
@Suite("Базы: замеры импорта и выгрузки", .enabled(if: ProcessInfo.processInfo.environment["MYNOTION_PERF"] != nil))
struct DatabaseImportPerformanceTests {
    private let workFolder: URL
    private let store: NotesStore

    init() throws {
        workFolder = FileManager.default.temporaryDirectory.appendingPathComponent("DatabasePerf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workFolder.appendingPathComponent("Выгрузки"), withIntermediateDirectories: true)
        store = NotesStore(database: try AppDatabase.open(at: workFolder.appendingPathComponent("MyNotion.sqlite")),
                           clock: HybridLogicalClock(deviceId: UUID()))
    }

    /// Выгрузка Notion «Markdown & CSV» с подстраницами: «Задачи» (`count` строк, 16 свойств всех угадываемых типов,
    /// связь с «Проектами») и «Проекты» (500 строк, столбец-пара).
    private func makeNotionExport(count: Int) throws -> URL {
        let root = workFolder.appendingPathComponent("notion/Базы a0000000000000000000000000000001", isDirectory: true)
        let tasksFolder = root.appendingPathComponent("Задачи"), projectsFolder = root.appendingPathComponent("Проекты")
        try FileManager.default.createDirectory(at: tasksFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectsFolder, withIntermediateDirectories: true)
        func hex(_ prefix: String, _ number: Int) -> String { prefix + String(format: "%031x", number) }
        let statuses = ["Не начато", "В работе", "Готово"], tags = ["Дом", "Работа", "Срочно", "Позже"]
        let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
        let header = "Name,Статус,Теги,Срок,Готово,Часы,Доля,Сайт,Почта,Телефон,ID,Проект,Итог,Created time,Last edited time,Заметки"
        var csv = "\u{FEFF}" + header + "\n"
        var projectLinks = Array(repeating: [String](), count: 500)
        for index in 0..<count {
            let title = "Задача \(index)"
            let project = index % 500
            let projectTitle = "Проект \(project)"
            projectLinks[project].append("\(title) (https://app.notion.com/p/\(hex("b", index))?pvs=21)")
            let due = "\(months[index % 12]) \(index % 28 + 1), 2026"
            let values = [title, statuses[index % 3], "\(tags[index % 4]), \(tags[(index + 1) % 4])", due, index % 2 == 0 ? "Yes" : "No",
                          "\(Double(index % 40) / 2)", "\(index % 100)%", "https://example.com/\(index)", "user\(index)@example.com",
                          "+7 900 \(String(format: "%07d", index))", "\(index + 1)",
                          "\(projectTitle) (https://app.notion.com/p/\(hex("c", project))?pvs=21)", "Итог \(index % 7)",
                          "October 1, 2026 9:\(String(format: "%02d", index % 60)) AM", "October 2, 2026 6:30 PM", "Заметка, номер \(index)"]
            csv += values.map(DatabaseCSVWriter.field).joined(separator: ",") + "\n"
            var md = "# \(title)\n\n"
            for (name, value) in zip(header.split(separator: ",").dropFirst(), values.dropFirst()) { md += "\(name): \(value)\n" }
            md += "\nТекст строки \(index).\n"
            try md.write(to: tasksFolder.appendingPathComponent("\(title) \(hex("b", index)).md"), atomically: false, encoding: .utf8)
        }
        try csv.write(to: root.appendingPathComponent("Задачи a0000000000000000000000000000002_all.csv"), atomically: false, encoding: .utf8)
        var projects = "\u{FEFF}Name,Задачи\n"
        for project in 0..<500 {
            projects += "Проект \(project),\(DatabaseCSVWriter.field(projectLinks[project].joined(separator: ", ")))\n"
            try "# Проект \(project)\n".write(to: projectsFolder.appendingPathComponent("Проект \(project) \(hex("c", project)).md"),
                                               atomically: false, encoding: .utf8)
        }
        try projects.write(to: root.appendingPathComponent("Проекты a0000000000000000000000000000003_all.csv"), atomically: false, encoding: .utf8)
        try "# Базы\n".write(to: root.appendingPathExtension("md"), atomically: false, encoding: .utf8)
        return workFolder.appendingPathComponent("notion")
    }

    @Test("Импорт 10 000 строк из Notion ≤ 60 с, правка во время импорта ждёт ≤ 100 мс")
    func importTenThousandRows() throws {
        let source = try makeNotionExport(count: 10_000)
        let editPage = try store.write { try $0.createPage(title: "Открытая страница") }
        let blockId = try #require(try store.pageContent(editPage.id)?.blocks.first?.id)

        // Правка открытой страницы раз в 50 мс, как автосохранение во время набора: сколько ждёт её запись.
        let waits = Mutex<[Double]>([])
        let running = Atomic<Bool>(true)
        let store = store
        let editor = Thread {
            var number = 0
            while running.load(ordering: .relaxed) {
                let start = Date()
                number += 1
                _ = try? store.write { tx throws in
                    guard var block = try tx.block(blockId) else { return }
                    block.text = InlineText("Правка \(number)")
                    try tx.updateBlock(block)
                }
                waits.withLock { $0.append(Date().timeIntervalSince(start) * 1_000) }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        editor.start()
        let start = Date()
        let prepared = try NotionExportUnpacker().prepare(source)
        let report = try NotionImporter(store: store).importExport(prepared)
        let seconds = Date().timeIntervalSince(start)
        running.store(false, ordering: .relaxed)
        prepared.discard()
        Thread.sleep(forTimeInterval: 0.1)

        let sorted = waits.withLock { $0 }.sorted()
        let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
        print("ЗАМЕР импорт 10 000 строк: \(String(format: "%.1f", seconds)) с; правка: медиана \(String(format: "%.1f", sorted[sorted.count / 2])) мс, p95 \(String(format: "%.1f", p95)) мс, макс \(String(format: "%.1f", sorted.last!)) мс, правок \(sorted.count)")
        #expect(report.databases.first { $0.title == "Задачи" }?.rowCount == 10_000)
        #expect(report.databases.first { $0.title == "Задачи" }?.properties.contains("Проект — связь с «Проекты», двусторонняя") == true)
        #expect(seconds <= 60)
        #expect(p95 <= 100)
    }

    @Test("Выгрузка «Задач» эталона (10 000 строк × 30 свойств) ≤ 10 с")
    func exportTasks() throws {
        let sample = try DatabaseSampleGenerator().ensure(in: store)
        let start = Date()
        let result = try MarkdownExporter(store: store).exportDatabase(sample.tasksId, into: workFolder.appendingPathComponent("Выгрузки"))
        let seconds = Date().timeIntervalSince(start)
        print("ЗАМЕР выгрузка «Задач» (10 000 строк): \(String(format: "%.1f", seconds)) с, страниц \(result.pageCount)")
        #expect(result.pageCount == DatabaseSampleGenerator.taskCount + 1)
        #expect(seconds <= 10)
    }
}
