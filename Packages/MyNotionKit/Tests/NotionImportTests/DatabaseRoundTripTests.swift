import Foundation
import NotesCore
import Testing
@testable import MarkdownExport
@testable import NotionImport

/// Круговая проверка (T060, FR-334, SC-310): эталон баз → своя выгрузка → импорт — схема, варианты, формулы, связи,
/// виды, шаблоны и значения один в один (id — новые, поэтому сравнение идёт по названиям вместо id).
@Suite("Базы: выгрузка → импорт")
struct DatabaseRoundTripTests {
    private let workFolder: URL
    private let store: NotesStore

    init() throws {
        workFolder = FileManager.default.temporaryDirectory.appendingPathComponent("DatabaseRoundTrip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workFolder.appendingPathComponent("Выгрузки"), withIntermediateDirectories: true)
        store = NotesStore(database: try AppDatabase.open(at: workFolder.appendingPathComponent("MyNotion.sqlite")),
                           clock: HybridLogicalClock(deviceId: UUID()))
    }

    /// Эталон 004 в малом размере и то, чего в нём нет: шаблон по умолчанию со значением, ручной порядок строки,
    /// удалённое свойство со значением.
    private func makeSample() throws -> DatabaseSampleGenerator.Sample {
        let sample = try DatabaseSampleGenerator(taskCount: 40, projectCount: 5).ensure(in: store)
        try store.write { tx throws in
            let rows = try tx.allPages().filter { $0.parentId == sample.tasksId }.sorted { $0.sortKey < $1.sortKey }
            let template = Page(title: "Новая задача", parentId: sample.tasksId, sortKey: .between(rows.last?.sortKey, nil),
                                createdAt: Date(timeIntervalSince1970: 1_790_000_000.25), updatedAt: Date(timeIntervalSince1970: 1_790_000_100.5),
                                isTemplate: true)
            try tx.setCell(rowId: template.id, propertyId: sample.taskProperties["Описание"]!, value: ["runs": [], "string": "Из шаблона"])
            try tx.insertPage(template)
            try tx.insertBlock(Block(pageId: template.id, kind: .checkbox, text: InlineText("Проверить"), sortKey: .between(nil, nil)))
            var schema = try #require(try tx.database(sample.tasksId))
            schema.defaultTemplateId = template.id
            try tx.saveDatabase(schema)
            try tx.setRowOrder(viewId: sample.tableViewId, rowId: rows[3].id, sortKey: .between(nil, rows[0].sortKey))
            var old = try #require(try tx.property(sample.taskProperties["Заметка"]!))
            old.deletedAt = Date(timeIntervalSince1970: 1_790_000_000)
            try tx.saveProperty(old)
        }
        return sample
    }

    @Test("Эталон баз → своя выгрузка → импорт: схема, варианты, формулы, связи, виды, шаблоны и значения один в один")
    func roundTrip() throws {
        let sample = try makeSample()
        let original = try canonicalDatabases([sample.tasksId, sample.projectsId, sample.inlineTasksId], in: store)

        let export = try MarkdownExporter(store: store).export(into: workFolder.appendingPathComponent("Выгрузки"))
        let prepared = try NotionExportUnpacker().prepare(export.folder)
        defer { prepared.discard() }
        let report = try NotionImporter(store: store).importExport(prepared)

        let imported = try store.pageOutline()
        func importedDatabase(_ title: String) throws -> UUID {
            let tree = PageTreeSnapshot(allPages: imported)
            let databases = Set(try store.write { tx throws in try tx.allDatabaseRecords() }.databases.map(\.pageId))
            return try #require(imported.first { page in
                page.title == title && databases.contains(page.id) && tree.isPage(page.id, insideBranchOf: report.rootPageId)
            }?.id)
        }
        let copies = try [DatabaseSampleGenerator.tasksTitle, DatabaseSampleGenerator.projectsTitle, DatabaseSampleGenerator.inlineTasksTitle]
            .map(importedDatabase)
        #expect(Set(copies).isDisjoint(with: [sample.tasksId, sample.projectsId, sample.inlineTasksId]))
        let roundTripped = try canonicalDatabases(copies, in: store)
        #expect(roundTripped.count == original.count)
        for (before, after) in zip(original, roundTripped) where before != after {
            Issue.record("было:  \(before)\nстало: \(after)")
        }
        // Своя выгрузка — без строк отчёта о потерях Notion.
        #expect(!report.notices.contains { NotionDatabaseReader.notionNotices.contains($0) })
        #expect(report.databases.map(\.title).sorted() == [DatabaseSampleGenerator.inlineTasksTitle, DatabaseSampleGenerator.projectsTitle,
                                                         DatabaseSampleGenerator.tasksTitle].sorted())
        // Встроенная — снова блок `database` в «Обзоре».
        let overview = try #require(imported.first { $0.title == DatabaseSampleGenerator.overviewTitle && $0.parentId != nil })
        #expect(try store.pageContent(overview.id)?.blocks.contains { $0.kind == .database && $0.linkedPageId == copies[2] } == true)
    }
}
