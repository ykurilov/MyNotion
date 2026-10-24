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

    /// База без id: каждый id заменён названием того, на что он указывает, — у исходной и у импортированной одинаково.
    private func canonical(_ databaseIds: [UUID]) throws -> [String] {
        let snapshots = try databaseIds.map { try #require(try DatabaseExportSnapshot.read($0, from: store)) }
        var labels: [String: String] = [:]
        for snapshot in snapshots {
            let base = snapshot.title
            labels[snapshot.schema.pageId.databaseText] = "база:\(base)"
            for property in snapshot.properties { labels[property.id.databaseText] = "свойство:\(base)/\(property.name)" }
            let names = Dictionary(uniqueKeysWithValues: snapshot.properties.map { ($0.id, $0.name) })
            for option in snapshot.options { labels[option.id.databaseText] = "вариант:\(names[option.propertyId] ?? "?")/\(option.name)" }
            for view in snapshot.views { labels[view.id.databaseText] = "вид:\(base)/\(view.name)" }
            for (index, row) in snapshot.rows.enumerated() { labels[row.id.databaseText] = "строка:\(base)/\(index)" }
            for (index, row) in snapshot.templates.enumerated() { labels[row.id.databaseText] = "шаблон:\(base)/\(index)" }
        }
        func label(_ value: JSONValue?) -> String {
            guard let value else { return "∅" }
            func walk(_ value: JSONValue) -> JSONValue {
                switch value {
                case .string(let text):
                    if let mapped = labels[text] { return .string(mapped) }
                    return .string(DatabaseSchemaImport.replacingIds(in: text, labels))
                case .array(let items): return .array(items.map(walk))
                case .object(let object): return .object(object.mapValues(walk))
                default: return value
                }
            }
            return walk(value).jsonText
        }
        var lines: [String] = []
        for snapshot in snapshots {
            let names = Dictionary(uniqueKeysWithValues: snapshot.properties.map { ($0.id, $0.name) })
            lines.append("база \(snapshot.title) встроенная=\(snapshot.schema.isInline) шаблон=\(label(snapshot.schema.defaultTemplateId.map { .string($0.databaseText) }))")
            for property in snapshot.properties {
                lines.append("свойство \(property.name) \(property.kind.rawValue) \(label(property.config)) удалено=\(property.deletedAt.map { "\($0.timeIntervalSince1970)" } ?? "нет")")
            }
            for option in snapshot.options { lines.append("вариант \(names[option.propertyId] ?? "?")/\(option.name) \(option.color) \(option.statusGroup?.rawValue ?? "")") }
            for view in snapshot.views {
                lines.append("вид \(view.name) \(view.type) \(label(view.filter)) \(label(view.sorts)) \(label(view.columns)) \(label(view.group)) \(label(view.layoutOptions))")
            }
            for order in snapshot.rowOrders { lines.append("порядок \(label(.string(order.viewId.databaseText))) \(label(.string(order.rowId.databaseText)))") }
            for row in snapshot.rows + snapshot.templates {
                var line = "строка «\(row.title)» шаблон=\(row.isTemplate) \(row.createdAt.timeIntervalSince1970) \(row.updatedAt.timeIntervalSince1970)"
                for (propertyId, value) in (snapshot.cells[row.id] ?? [:]).sorted(by: { names[$0.key] ?? "" < names[$1.key] ?? "" }) {
                    line += " | \(names[propertyId] ?? "?")=\(label(value))"
                }
                for (propertyId, targets) in (snapshot.relations[row.id] ?? [:]).sorted(by: { names[$0.key] ?? "" < names[$1.key] ?? "" }) {
                    var labels = targets.map { label(.string($0.databaseText)) }
                    // Ответная сторона пары своего порядка не хранит: связи идут по ключам другой стороны, а при равных
                    // ключах — по id связи, который при импорте новый. Сторона хранения сравнивается по порядку.
                    let paired = snapshot.properties.first { $0.id == propertyId }?.config["pairedPropertyId"]?.string
                        .flatMap(UUID.init(uuidString:))
                    if let paired, paired < propertyId { labels.sort() }
                    line += " | \(names[propertyId] ?? "?")→\(labels.joined(separator: ","))"
                }
                let body = try #require(try store.pageContent(row.id)).blocks.map { "\($0.kind.rawValue):\($0.text.string)" }
                lines.append(line + " | тело " + body.joined(separator: " / "))
            }
        }
        return lines
    }

    @Test("Эталон баз → своя выгрузка → импорт: схема, варианты, формулы, связи, виды, шаблоны и значения один в один")
    func roundTrip() throws {
        let sample = try makeSample()
        let original = try canonical([sample.tasksId, sample.projectsId, sample.inlineTasksId])

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
        let roundTripped = try canonical(copies)
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
