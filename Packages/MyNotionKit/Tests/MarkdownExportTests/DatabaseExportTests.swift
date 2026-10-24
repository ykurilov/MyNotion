import Databases
import Foundation
import NotesCore
import Testing
@testable import MarkdownExport

/// Выгрузка базы (T058, contracts/sync-v4-and-export.md, «Выгрузка базы»): CSV как у Notion, Markdown строк, схема;
/// встроенная — в папке хозяина; шаблоны — в `Шаблоны/`.
@Suite("Выгрузка баз")
struct DatabaseExportTests {
    private let workFolder: URL
    private let store: NotesStore
    private let exportDate = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 15))!
    private let zone = "Europe/Moscow"

    private struct Sample {
        var owner: UUID
        var tasks: UUID
        var projects: UUID
        var inline: UUID
        var rows: [UUID]
        var template: UUID
        var properties: [String: UUID]
        var alpha: UUID
    }

    init() throws {
        workFolder = FileManager.default.temporaryDirectory.appendingPathComponent("DatabaseExportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workFolder.appendingPathComponent("Выгрузки"), withIntermediateDirectories: true)
        store = NotesStore(database: try AppDatabase.open(at: workFolder.appendingPathComponent("MyNotion.sqlite")),
                           clock: HybridLogicalClock(deviceId: UUID()))
    }

    private func local(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    /// «Хозяин»: полностраничная «Задачи» (все простые типы, связь-пара с «Проектами», формула, шаблон, скрытая колонка,
    /// удалённое свойство) и встроенная «Встроенная».
    private func makeSample() throws -> Sample {
        try store.write { tx throws -> Sample in
            let owner = try tx.createPage(title: "Хозяин")
            var sortKey: FractionalSortKey?
            func page(_ title: String, parent: UUID, created: Date, isTemplate: Bool = false) throws -> UUID {
                sortKey = .between(sortKey, nil)
                let page = Page(title: title, parentId: parent, sortKey: sortKey!, createdAt: created, updatedAt: created, isTemplate: isTemplate)
                try tx.insertPage(page)
                return page.id
            }
            func database(_ title: String, isInline: Bool) throws -> UUID {
                let id = try page(title, parent: owner.id, created: local(17, 12, 0))
                try tx.saveDatabase(DatabaseSchema(pageId: id, isInline: isInline))
                let last = try tx.blocks(ofPage: owner.id).last?.sortKey
                try tx.insertBlock(Block(pageId: owner.id, kind: isInline ? .database : .pageLink, linkedPageId: id, sortKey: .between(last, nil)))
                return id
            }
            let tasks = try database("Задачи", isInline: false)
            let projects = try database("Проекты", isInline: false)
            let inline = try database("Встроенная", isInline: true)
            // Пустой абзац новой страницы не нужен: хозяин — только ссылки на базы.
            try tx.deleteBlock(try tx.blocks(ofPage: owner.id)[0].id)

            var properties: [String: UUID] = [:]
            var propertyKey: FractionalSortKey?
            func property(_ name: String, _ kind: PropertyKind, in database: UUID = tasks, config: JSONValue = .emptyObject,
                          deleted: Bool = false) throws -> UUID {
                propertyKey = .between(propertyKey, nil)
                let property = try tx.saveProperty(DatabaseProperty(databaseId: database, name: name, kind: kind, config: config,
                                                                    sortKey: propertyKey!, deletedAt: deleted ? Date() : nil))
                properties[database == tasks ? name : "\(name)@\(database)"] = property.id
                return property.id
            }
            let title = try property("Название", .title)
            let status = try property("Статус", .select)
            let tags = try property("Теги", .multiSelect)
            let due = try property("Срок", .date)
            let done = try property("Готово", .checkbox)
            let hours = try property("Часы", .number)
            let share = try property("Доля", .number, config: ["format": "percent"])
            let site = try property("Сайт", .url)
            let number = try property("ID", .uniqueId, config: ["prefix": "ЗАД"])
            let projectTitle = try property("Название", .title, in: projects)
            let projectTasks = try property("Задачи", .relation, in: projects, config: ["targetDatabaseId": .string(tasks.databaseText), "limit": "none"])
            let project = try property("Проект", .relation, config: ["targetDatabaseId": .string(projects.databaseText), "limit": "none",
                                                                     "pairedPropertyId": .string(projectTasks.databaseText)])
            var paired = try #require(try tx.property(projectTasks))
            paired.config["pairedPropertyId"] = .string(project.databaseText)
            try tx.saveProperty(paired)
            let total = try property("Итог", .formula, config: ["expression": "\"Привет\""])
            _ = try property("Создано", .createdTime)
            let notes = try property("Заметки", .text)
            let hidden = try property("Скрытое", .text)
            _ = try property("Старое", .text, deleted: true)
            _ = try property("Название", .title, in: inline)

            func option(_ name: String, _ property: UUID, _ color: OptionColor) throws -> String {
                propertyKey = .between(propertyKey, nil)
                return try tx.saveOption(SelectOption(propertyId: property, name: name, color: color, sortKey: propertyKey!)).id.databaseText
            }
            let ready = try option("Готово", status, .green)
            let home = try option("Дом", tags, .blue)
            let urgent = try option("Срочно", tags, .red)
            try tx.saveView(DatabaseView(databaseId: tasks, sortKey: .between(nil, nil), columns: [
                ["propertyId": .string(title.databaseText), "isVisible": true, "width": 280],
                ["propertyId": .string(due.databaseText), "isVisible": true],
                ["propertyId": .string(status.databaseText), "isVisible": true],
                ["propertyId": .string(hidden.databaseText), "isVisible": false],
            ]))
            _ = projectTitle

            let call = try page("Позвонить в банк", parent: tasks, created: local(18, 9, 0))
            let milk = try page("Купить молоко, хлеб", parent: tasks, created: local(18, 9, 5))
            let template = try page("Новая задача", parent: tasks, created: local(18, 9, 10), isTemplate: true)
            let alpha = try page("Альфа", parent: projects, created: local(18, 8, 0))
            try tx.setCell(rowId: call, propertyId: status, value: .string(ready))
            try tx.setCell(rowId: call, propertyId: tags, value: [.string(home), .string(urgent)])
            try tx.setCell(rowId: call, propertyId: due, value: ["start": "2026-10-22", "end": "2026-10-24", "hasTime": false, "timeZone": .string(zone)])
            try tx.setCell(rowId: call, propertyId: done, value: true)
            try tx.setCell(rowId: call, propertyId: hours, value: 1.5)
            try tx.setCell(rowId: call, propertyId: share, value: 0.5)
            try tx.setCell(rowId: call, propertyId: site, value: "https://example.com")
            try tx.setCell(rowId: call, propertyId: number, value: 1)
            try tx.setCell(rowId: call, propertyId: notes, value: ["runs": [], "string": "Две строки\nзаметки"])
            try tx.setCell(rowId: milk, propertyId: due, value: ["start": "2026-10-21T15:15", "hasTime": true, "timeZone": .string(zone)])
            try tx.setCell(rowId: milk, propertyId: number, value: 2)
            try tx.setCell(rowId: template, propertyId: status, value: .string(ready))
            try tx.saveRelationLink(RelationLink(propertyId: min(project, projectTasks), rowId: project < projectTasks ? call : alpha,
                                                 targetRowId: project < projectTasks ? alpha : call, sortKey: .between(nil, nil)))
            try ComputedWriter.write([ComputedValue(rowId: call, propertyId: total, value: "Привет")], in: tx)
            try tx.insertBlock(Block(pageId: call, kind: .paragraph, text: InlineText("Тело строки."), sortKey: .between(nil, nil)))
            // Запись ячейки сдвигает «изменено»: возвращаем время создания, чтобы сравнивать дословно.
            for (row, date) in [(call, local(18, 9, 0)), (milk, local(18, 9, 5))] {
                try tx.database.execute(sql: "UPDATE page SET updatedAt = ? WHERE id = ?", arguments: [date, row.databaseText])
            }
            return Sample(owner: owner.id, tasks: tasks, projects: projects, inline: inline, rows: [call, milk], template: template,
                          properties: properties, alpha: alpha)
        }
    }

    private func export() throws -> URL {
        try MarkdownExporter(store: store, now: { [exportDate] in exportDate })
            .export(into: workFolder.appendingPathComponent("Выгрузки")).folder
    }

    private func text(_ folder: URL, _ path: String) throws -> String {
        try String(contentsOf: folder.appendingPathComponent(path), encoding: .utf8)
    }

    @Test("Файлы: полностраничная и встроенная — CSV, папка строк и схема рядом со страницей-хозяином; шаблоны — в «Шаблоны/»")
    func layout() throws {
        _ = try makeSample()
        let folder = try export()
        let manager = FileManager.default
        for path in ["Хозяин.md", "Хозяин/Задачи.csv", "Хозяин/Задачи.mynotion-database.json", "Хозяин/Задачи/Позвонить в банк.md",
                     "Хозяин/Задачи/Купить молоко, хлеб.md", "Хозяин/Задачи/Шаблоны/Новая задача.md", "Хозяин/Встроенная.csv",
                     "Хозяин/Проекты.csv", "Хозяин/Проекты/Альфа.md"] {
            #expect(manager.fileExists(atPath: folder.appendingPathComponent(path).path), "нет «\(path)»")
        }
        #expect(!manager.fileExists(atPath: folder.appendingPathComponent("Хозяин/Задачи.md").path))
        // Ссылки хозяина — на CSV баз (у Notion так же).
        #expect(try text(folder, "Хозяин.md") == "# Хозяин\n\n[Задачи](Хозяин/Задачи.csv)\n\n[Проекты](Хозяин/Проекты.csv)\n\n[Встроенная](Хозяин/Встроенная.csv)\n")
    }

    @Test("CSV: BOM, запятая, кавычки RFC 4180; название, колонки первого вида (и скрытые), остальные свойства; значения как у Notion")
    func csv() throws {
        _ = try makeSample()
        let folder = try export()
        let data = try Data(contentsOf: folder.appendingPathComponent("Хозяин/Задачи.csv"))
        #expect(data.prefix(3) == Data([0xEF, 0xBB, 0xBF]))
        // Текст без BOM: чтение строки в UTF-8 его отрезает (он проверен по байтам выше).
        #expect(try text(folder, "Хозяин/Задачи.csv") == """
        Название,Срок,Статус,Скрытое,Теги,Готово,Часы,Доля,Сайт,ID,Проект,Итог,Создано,Заметки
        Позвонить в банк,"October 22, 2026 → October 24, 2026",Готово,,"Дом, Срочно",Yes,1.5,50%,https://example.com,ЗАД-1,Альфа (Проекты/Альфа.md),Привет,"October 18, 2026 9:00 AM","Две строки
        заметки"
        "Купить молоко, хлеб","October 21, 2026 3:15 PM",,,,No,,,,ЗАД-2,,,"October 18, 2026 9:05 AM",

        """)
        // Ответная колонка пары видит связь, хранящуюся у другой стороны.
        #expect(try text(folder, "Хозяин/Проекты.csv") == "Название,Задачи\nАльфа,Позвонить в банк (Задачи/Позвонить в банк.md)\n")
    }

    @Test("Markdown строки: «# Название», непустые «Свойство: значение» в порядке CSV, пустая строка, тело")
    func rowMarkdown() throws {
        _ = try makeSample()
        let folder = try export()
        #expect(try text(folder, "Хозяин/Задачи/Позвонить в банк.md") == """
        # Позвонить в банк

        Срок: October 22, 2026 → October 24, 2026
        Статус: Готово
        Теги: Дом, Срочно
        Готово: Yes
        Часы: 1.5
        Доля: 50%
        Сайт: https://example.com
        ID: ЗАД-1
        Проект: Альфа (../Проекты/Альфа.md)
        Итог: Привет
        Создано: October 18, 2026 9:00 AM
        Заметки: Две строки
        заметки

        Тело строки.

        """)
        #expect(try text(folder, "Хозяин/Задачи/Шаблоны/Новая задача.md") == "# Новая задача\n\nСтатус: Готово\nГотово: No\nСоздано: October 18, 2026 9:10 AM\n")
    }

    @Test("Схема: свойства с типами и настройками (и удалённые), варианты с цветами, виды, строки с файлами и значениями, шаблоны")
    func schema() throws {
        let sample = try makeSample()
        let folder = try export()
        let schema = try DatabaseSchemaFile.decoded(from: Data(contentsOf: folder.appendingPathComponent("Хозяин/Задачи.mynotion-database.json")))
        #expect(schema.formatVersion == DatabaseSchemaFile.currentFormatVersion)
        #expect(schema.databaseId == sample.tasks.databaseText && schema.title == "Задачи" && !schema.isInline)
        #expect(schema.properties.map(\.name) == ["Название", "Статус", "Теги", "Срок", "Готово", "Часы", "Доля", "Сайт", "ID", "Проект",
                                                   "Итог", "Создано", "Заметки", "Скрытое", "Старое"])
        #expect(schema.properties.last?.deletedAt != nil)
        #expect(schema.properties.first { $0.name == "Итог" }?.config["expression"] == "\"Привет\"")
        #expect(schema.properties.first { $0.name == "Проект" }?.relationTarget == "Проекты.csv")
        #expect(schema.options.map(\.name) == ["Готово", "Дом", "Срочно"])
        #expect(schema.options.map(\.color) == ["green", "blue", "red"])
        #expect(schema.views.count == 1 && schema.views[0].columns.array?.count == 4)
        #expect(schema.rows.map(\.file) == ["Задачи/Позвонить в банк.md", "Задачи/Купить молоко, хлеб.md"])
        #expect(schema.rows[0].createdAt == local(18, 9, 0))
        #expect(schema.rows[0].cells[sample.properties["Часы"]!.databaseText] == 1.5)
        #expect(schema.rows[0].relations[sample.properties["Проект"]!.databaseText] == [sample.alpha.databaseText])
        #expect(schema.templates.map(\.file) == ["Задачи/Шаблоны/Новая задача.md"])
        let inline = try DatabaseSchemaFile.decoded(from: Data(contentsOf: folder.appendingPathComponent("Хозяин/Встроенная.mynotion-database.json")))
        #expect(inline.isInline)
    }

    @Test("«Выгрузить базу»: только эта база — CSV, строки, схема — в новой папке")
    func singleDatabase() throws {
        let sample = try makeSample()
        let result = try MarkdownExporter(store: store, now: { [exportDate] in exportDate })
            .exportDatabase(sample.tasks, into: workFolder.appendingPathComponent("Выгрузки"))
        let names = try FileManager.default.contentsOfDirectory(atPath: result.folder.path).sorted()
        #expect(names == ["Задачи", "Задачи.csv", "Задачи.mynotion-database.json"])
        #expect(result.folder.lastPathComponent == "Задачи-выгрузка-2026-10-21")
        #expect(try text(result.folder, "Задачи/Позвонить в банк.md").hasPrefix("# Позвонить в банк\n"))
    }
}
