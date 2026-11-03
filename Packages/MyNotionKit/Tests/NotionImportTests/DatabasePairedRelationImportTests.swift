import Foundation
import NotesCore
import Testing
@testable import Databases
@testable import MarkdownExport
@testable import NotionImport

/// Выгрузка одной базы с двусторонней связью на базу вне выгрузки → импорт: у копии связь односторонняя на те же
/// строки (вторая сторона пары осталась у оригинала), связи копии видны, связи оригинала не тронуты.
@Suite("Базы: импорт выгрузки одной базы с парной связью")
struct DatabasePairedRelationImportTests {
    private let workFolder: URL
    private let store: NotesStore
    private let sample: DatabaseSampleGenerator.Sample

    init() throws {
        workFolder = FileManager.default.temporaryDirectory.appendingPathComponent("PairedRelationImport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workFolder.appendingPathComponent("Выгрузки"), withIntermediateDirectories: true)
        store = NotesStore(database: try AppDatabase.open(at: workFolder.appendingPathComponent("MyNotion.sqlite")),
                           clock: HybridLogicalClock(deviceId: UUID()))
        sample = try DatabaseSampleGenerator(taskCount: 40, projectCount: 5).ensure(in: store)
    }

    /// Строка (название) → названия связанных строк через свойство `name`, по порядку.
    private func relations(of databaseId: UUID, _ name: String) throws -> [String: [String]] {
        let catalog = try DatabaseCatalog.read(databaseId, in: store)
        let property = try #require(catalog.properties.first { $0.name == name })
        let rows = try store.write { tx throws in try tx.allPages().filter { $0.parentId == databaseId && $0.trashedAt == nil }.map(\.id) }
        let read = try RowWindowReader.read(rows, catalog: catalog, store: store)
        return Dictionary(uniqueKeysWithValues: rows.compactMap { row in read[row].map { ($0.title, $0.relations[property.id]?.map(\.title) ?? []) } })
    }

    private func importCopy(of databaseId: UUID) throws -> UUID {
        let export = try MarkdownExporter(store: store).exportDatabase(databaseId, into: workFolder.appendingPathComponent("Выгрузки"))
        let prepared = try NotionExportUnpacker().prepare(export.folder)
        defer { prepared.discard() }
        let report = try NotionImporter(store: store).importExport(prepared)
        let tree = PageTreeSnapshot(allPages: try store.pageOutline())
        let title = try store.pageContent(databaseId)?.page.title
        let databases = Set(try store.write { tx throws in try tx.allDatabaseRecords() }.databases.map(\.pageId))
        return try #require(try store.pageOutline().first { page in
            page.title == title && page.id != databaseId && databases.contains(page.id) && tree.isPage(page.id, insideBranchOf: report.rootPageId)
        }?.id)
    }

    @Test("Выгружена одна сторона пары — копия видит те же связи, пара оригинала не тронута", arguments: [
        ("Задачи", "Проект", "Проекты", "Задачи"),
        ("Проекты", "Задачи", "Задачи", "Проект"),
    ])
    func importsOneSideOfPair(exported: String, relation: String, other: String, back: String) throws {
        let databaseId = exported == "Задачи" ? sample.tasksId : sample.projectsId
        let otherId = other == "Задачи" ? sample.tasksId : sample.projectsId
        let before = try relations(of: databaseId, relation)
        let otherBefore = try relations(of: otherId, back)
        #expect(before.values.contains { !$0.isEmpty })

        let copy = try importCopy(of: databaseId)
        let copiedRelation = try #require(try DatabaseCatalog.read(copy, in: store).properties.first { $0.name == relation })
        #expect(copiedRelation.relationTarget == otherId)
        #expect(copiedRelation.pairedRelation == nil, "вторая сторона пары осталась у оригинала — у копии связь односторонняя")
        #expect(try relations(of: copy, relation) == before, "связи копии — на те же строки")
        #expect(try relations(of: databaseId, relation) == before, "связи оригинала не тронуты")
        #expect(try relations(of: otherId, back) == otherBefore, "у другой базы не появилось связей на строки копии")
        let backProperty = try #require(try DatabaseCatalog.read(otherId, in: store).properties.first { $0.name == back })
        let originalRelation = try #require(try DatabaseCatalog.read(databaseId, in: store).properties.first { $0.name == relation })
        #expect(backProperty.pairedRelation == originalRelation.id)
    }
}
