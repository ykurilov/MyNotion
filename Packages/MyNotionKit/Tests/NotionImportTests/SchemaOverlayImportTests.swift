import Foundation
import GRDB
import NotesCore
import NotionSchemaFetch
import Testing
@testable import Databases
@testable import NotionImport

/// Схема Notion поверх CSV-импорта (T107, research R19): точные типы, цвета, статусы с группами, формулы, сводки, пары связей.
@Suite("Импорт баз из Notion: схема поверх CSV")
struct SchemaOverlayImportTests {
    private let workFolder: URL
    private let store: NotesStore
    private let importDate = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 15))!
    private static let tasksId = "a0000000000000000000000000000002"
    private static let projectsId = "a0000000000000000000000000000003"

    init() throws {
        workFolder = FileManager.default.temporaryDirectory.appendingPathComponent("SchemaOverlayImport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workFolder, withIntermediateDirectories: true)
        store = NotesStore(database: try AppDatabase.open(at: workFolder.appendingPathComponent("MyNotion.sqlite")),
                           clock: HybridLogicalClock(deviceId: UUID()))
    }

    /// Выгрузка «синтетическая» с полной таблицей «Проектов»: в настоящей выгрузке формулы и сводки идут столбцами.
    private func export() throws -> URL {
        let copy = workFolder.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.copyItem(at: NotionDatabaseImportTests.synthetic, to: copy)
        let owner = copy.appendingPathComponent("MyNotion — базы 004 a0000000000000000000000000000001", isDirectory: true)
        let csv = """
        \u{FEFF}Name,Задачи,Бюджет,Всего часов,Бюджет за час,Стиль
        Альфа,"Купить молоко (https://app.notion.com/p/b0000000000000000000000000000001?pvs=21), Купить молоко (https://app.notion.com/p/b0000000000000000000000000000002?pvs=21)",1000,3.5,285.7,Привет
        Бета,"Купить молоко (https://app.notion.com/p/b0000000000000000000000000000002?pvs=21), Позвонить в банк (https://app.notion.com/p/b0000000000000000000000000000003?pvs=21)",2500.5,2,1250.25,Мир

        """
        for name in ["Проекты \(Self.projectsId).csv", "Проекты \(Self.projectsId)_all.csv"] {
            try csv.write(to: owner.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return copy
    }

    private func schema(_ file: String) throws -> NotionDatabaseSchema {
        let url = try #require(Bundle.module.url(forResource: file, withExtension: "json", subdirectory: "Fixtures/NotionSchema"))
        return try NotionSchemaMapping.schema(fromDataSource: Data(contentsOf: url))
    }

    private func bothSchemas() throws -> NotionSchemaFetchResult {
        NotionSchemaFetchResult(schemas: [Self.tasksId: try schema("import-tasks-data-source"),
                                          Self.projectsId: try schema("import-projects-data-source")])
    }

    @discardableResult
    private func runImport(_ result: NotionSchemaFetchResult) throws -> NotionImportReport {
        let prepared = try NotionExportUnpacker().prepare(export())
        defer { prepared.discard() }
        return try NotionImporter(store: store, now: { [importDate] in importDate }).importExport(prepared, schema: result)
    }

    private func database(_ title: String, _ report: NotionImportReport) throws -> UUID {
        let owner = try #require(try store.pageOutline().first { $0.title == "MyNotion — базы 004" && $0.parentId == report.rootPageId })
        return try #require(try store.pageOutline().first { $0.title == title && $0.parentId == owner.id }).id
    }

    private func properties(_ databaseId: UUID) throws -> [String: DatabaseProperty] {
        Dictionary(uniqueKeysWithValues: try store.write { try $0.properties(ofDatabase: databaseId) }.map { ($0.name, $0) })
    }

    private func options(_ property: DatabaseProperty) throws -> [SelectOption] {
        try store.write { try $0.options(ofProperty: property.id) }.sorted { $0.sortKey < $1.sortKey }
    }

    private func rows(_ databaseId: UUID) throws -> [Page] {
        try store.pageOutline().filter { $0.parentId == databaseId && !$0.isTemplate }.sorted { $0.sortKey < $1.sortKey }
    }

    @Test("Типы берутся из схемы: статус с группами, цвета вариантов, число с форматом, пустой столбец-тип")
    func typesFromSchema() throws {
        let report = try runImport(bothSchemas())
        let tasks = try database("Задачи", report)
        let properties = try properties(tasks)
        #expect(properties["Статус"]?.kind == .status)
        let status = try options(#require(properties["Статус"]))
        #expect(status.map(\.name) == ["Не начато", "Отложено", "В работе", "Готово"])
        #expect(status.map(\.statusGroup) == [.todo, .todo, .inProgress, .complete])
        #expect(Dictionary(uniqueKeysWithValues: status.map { ($0.name, $0.color) }) == ["Не начато": "default", "Отложено": "gray", "В работе": "blue", "Готово": "green"])
        #expect(properties["Теги"]?.kind == .multiSelect)
        let tags = try options(#require(properties["Теги"]))
        #expect(tags.map(\.name) == ["Дом", "Срочно", "Работа"])
        #expect(tags.map(\.color) == ["brown", "red", "purple"])
        #expect(properties["Доля"]?.config["format"]?.string == "percent")
        #expect(properties["Часы"]?.kind == .number)
        #expect(properties["Ответственный"]?.kind == .text)
        #expect(properties["ID"]?.kind == .uniqueId)
        // Значение статуса записано как вариант.
        let first = try #require(try rows(tasks).first)
        let cell = try store.write { try $0.cell(rowId: first.id, propertyId: #require(properties["Статус"]).id) }?.value
        #expect(status.first { $0.id.uuidString.lowercased() == cell?.string }?.name == "Готово")
    }

    @Test("Формула Notion переносится формулой MyNotion: ссылки по id, значения в ячейки не пишутся, после пересчёта итог верный")
    func formulaIsKept() throws {
        let report = try runImport(bothSchemas())
        let tasks = try database("Задачи", report)
        let properties = try properties(tasks)
        let done = try #require(properties["Готово"])
        let total = try #require(properties["Итог"])
        #expect(total.kind == .formula)
        #expect(total.config["expression"]?.string == "if(prop(\"\(done.id.databaseText)\"), \"Привет\", \"Пока\")")
        let rows = try rows(tasks)
        #expect(try store.write { try $0.cell(rowId: rows[0].id, propertyId: total.id) } == nil)
        _ = try FormulaRecompute(store: store, databaseId: tasks).recomputeAll()
        func computed(_ row: Page) throws -> String? {
            try store.database.dbWriter.read { db in
                try String.fetchOne(db, sql: "SELECT value FROM db_computed WHERE rowId = ? AND propertyId = ?", arguments: [row.id.databaseText, total.id.databaseText])
            }
        }
        #expect(try computed(rows[0])?.contains("Привет") == true)
        #expect(try computed(rows[1])?.contains("Пока") == true)
    }

    @Test("Связь с парой: цель и ответное свойство — по схеме; сводка смотрит на свои связь и свойство цели; формула с названиями из двух баз")
    func relationsRollupsAndFormulas() throws {
        let report = try runImport(bothSchemas())
        let tasks = try database("Задачи", report)
        let projects = try database("Проекты", report)
        let taskProperties = try properties(tasks), projectProperties = try properties(projects)
        let project = try #require(taskProperties["Проект"]), backlink = try #require(projectProperties["Задачи"])
        #expect(project.config["targetDatabaseId"]?.string == projects.databaseText)
        #expect(project.config["pairedPropertyId"]?.string == backlink.id.databaseText)
        #expect(backlink.config["pairedPropertyId"]?.string == project.id.databaseText)

        let rollup = try #require(projectProperties["Всего часов"])
        #expect(rollup.kind == .rollup)
        #expect(rollup.config["relationPropertyId"]?.string == backlink.id.databaseText)
        #expect(rollup.config["targetPropertyId"]?.string == taskProperties["Часы"]?.id.databaseText)
        #expect(rollup.config["calculation"]?.string == "sum")

        let perHour = try #require(projectProperties["Бюджет за час"])
        #expect(perHour.kind == .formula)
        #expect(perHour.config["expression"]?.string
            == "prop(\"\(try #require(projectProperties["Бюджет"]).id.databaseText)\") / prop(\"\(rollup.id.databaseText)\")")
        #expect(projectProperties["Бюджет"]?.config["format"]?.string == "ruble")
    }

    @Test("Формула, которой нет в MyNotion, остаётся значениями из CSV; в отчёте — какая и почему")
    func untranslatableFormulaFallsBack() throws {
        let report = try runImport(bothSchemas())
        let projects = try database("Проекты", report)
        let style = try #require(try properties(projects)["Стиль"])
        #expect(style.kind == .text)
        let summary = try #require(report.databases.first { $0.title == "Проекты" })
        let note = try #require(summary.notes.first { $0.contains("Стиль") })
        #expect(note.contains("style"))
        #expect(summary.properties.contains { $0.hasPrefix("Бюджет за час — формула") })
    }

    @Test("Отчёт: схема применена; общие потери «формулы и сводки значениями» и «статус стал выбором» снимаются")
    func reportReflectsSchema() throws {
        let report = try runImport(bothSchemas())
        #expect(report.databases.allSatisfy { $0.schemaApplied })
        #expect(!report.notices.contains { $0.contains("Формулы и сводки Notion приходят") })
        #expect(!report.notices.contains { $0.contains("Статусы Notion стали выбором") })
        #expect(report.notices.contains { $0.contains("Люди") })
        let status = try #require(report.databases.first { $0.title == "Задачи" }?.properties.first { $0.hasPrefix("Статус") })
        #expect(status == "Статус — статус")
    }

    @Test("Схему одной базы прочитать не удалось: она импортируется по CSV с причиной, другая — по схеме")
    func partialFailure() throws {
        var result = NotionSchemaFetchResult(schemas: [Self.projectsId: try schema("import-projects-data-source")])
        result.failures = [NotionSchemaFailure(databaseId: Self.tasksId, reason: .noAccess)]
        let report = try runImport(result)
        let tasks = try database("Задачи", report)
        #expect(try properties(tasks)["Статус"]?.kind == .select)
        let summary = try #require(report.databases.first { $0.title == "Задачи" })
        #expect(summary.schemaApplied == false)
        #expect(summary.notes.contains { $0.contains("Подключения") })
        #expect(report.notices.contains { $0.contains("Формулы и сводки Notion приходят") })
        // У «Проектов» цель сводки — в нечитанной базе: сводка остаётся значениями, причина названа.
        let projects = try #require(report.databases.first { $0.title == "Проекты" })
        #expect(projects.notes.contains { $0.contains("Всего часов") })
    }

    @Test("Сводка по схеме, у которой во втором проходе нет свойства цели: значения из CSV сохранены угаданным типом, причина — в отчёте")
    func rollupWithoutTargetKeepsCsvValues() throws {
        // В таблице «Задач» нет столбца «Часы», хотя схема его знает: сводка «Всего часов» ссылается на пустоту.
        let copy = try export()
        let owner = copy.appendingPathComponent("MyNotion — базы 004 a0000000000000000000000000000001", isDirectory: true)
        do {
            let url = owner.appendingPathComponent("Задачи \(Self.tasksId)_all.csv")
            var rows = NotionCSV.rows(try String(contentsOf: url, encoding: .utf8)).filter { !$0.isEmpty }
            let hours = try #require(rows[0].firstIndex(of: "Часы"))
            rows = rows.map { row in row.enumerated().filter { $0.offset != hours }.map(\.element) }
            let text = "\u{FEFF}" + rows.map { row in
                row.map { $0.contains(where: { ",\"\n".contains($0) }) ? "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : $0 }
                    .joined(separator: ",")
            }.joined(separator: "\n") + "\n"
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        let prepared = try NotionExportUnpacker().prepare(copy)
        defer { prepared.discard() }
        let report = try NotionImporter(store: store, now: { [importDate] in importDate })
            .importExport(prepared, schema: bothSchemas())

        let projects = try database("Проекты", report)
        let hours = try #require(try properties(projects)["Всего часов"])
        #expect(hours.kind == .number)
        let values: [JSONValue?] = try rows(projects).map { row in
            try store.write { try $0.cell(rowId: row.id, propertyId: hours.id) }?.value
        }
        #expect(values == [.number(3.5), .number(2)])
        let summary = try #require(report.databases.first { $0.title == "Проекты" })
        #expect(summary.properties.contains { $0.hasPrefix("Всего часов — число") })
        let note = try #require(summary.notes.first { $0.contains("Всего часов") })
        #expect(note.contains("Часы"))
        #expect(note.contains("значения из выгрузки"))
    }

    @Test("Id баз для дочитывания схемы — таблицы выгрузки без служебных копий _all")
    func databaseIdsOfExport() throws {
        let prepared = try NotionExportUnpacker().prepare(export())
        defer { prepared.discard() }
        #expect(prepared.databaseIds().contains(Self.tasksId))
        #expect(prepared.databaseIds().contains(Self.projectsId))
        #expect(Set(prepared.databaseIds()).count == prepared.databaseIds().count)
    }

    @Test("Без схемы импорт прежний: ничего не сказано про схему")
    func withoutSchemaNothingChanges() throws {
        let report = try runImport(NotionSchemaFetchResult())
        #expect(report.databases.allSatisfy { !$0.schemaApplied })
        #expect(report.databases.allSatisfy { !$0.notes.contains { $0.contains("Схема") } })
        #expect(try properties(database("Задачи", report))["Статус"]?.kind == .select)
    }
}
