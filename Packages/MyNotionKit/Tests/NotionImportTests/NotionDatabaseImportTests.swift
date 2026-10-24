import Foundation
import NotesCore
import Testing
@testable import NotionImport

/// Импорт баз из выгрузки Notion «Markdown & CSV» (T059, contracts/sync-v4-and-export.md, «Импорт выгрузки Notion»).
@Suite("Импорт баз из Notion")
struct NotionDatabaseImportTests {
    private let workFolder: URL
    private let store: NotesStore
    private let importDate = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 15))!

    static let fixtures = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/NotionDatabases", isDirectory: true)
    static let synthetic = fixtures.appendingPathComponent("synthetic", isDirectory: true)
    static let noSubpages = fixtures.appendingPathComponent("no-subpages", isDirectory: true)

    init() throws {
        workFolder = FileManager.default.temporaryDirectory.appendingPathComponent("NotionDatabaseImport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workFolder, withIntermediateDirectories: true)
        store = NotesStore(database: try AppDatabase.open(at: workFolder.appendingPathComponent("MyNotion.sqlite")),
                           clock: HybridLogicalClock(deviceId: UUID()))
    }

    @discardableResult
    private func runImport(_ source: URL = synthetic) throws -> NotionImportReport {
        let prepared = try NotionExportUnpacker().prepare(source)
        defer { prepared.discard() }
        return try NotionImporter(store: store, now: { [importDate] in importDate }).importExport(prepared)
    }

    private func pages() throws -> [Page] { try store.pageOutline() }

    private func page(_ title: String, parent: UUID?) throws -> Page {
        try #require(try pages().first { $0.title == title && $0.parentId == parent && $0.trashedAt == nil }, "Нет страницы «\(title)»")
    }

    /// Строки базы по порядку (без шаблонов).
    private func rows(of databaseId: UUID) throws -> [Page] {
        try pages().filter { $0.parentId == databaseId && !$0.isTemplate }.sorted { $0.sortKey < $1.sortKey }
    }

    private func read<T>(_ body: (NotesTransaction) throws -> T) throws -> T {
        try store.write { tx throws in try body(tx) }
    }

    private func property(_ name: String, of databaseId: UUID) throws -> DatabaseProperty {
        try #require(try read { try $0.properties(ofDatabase: databaseId) }.first { $0.name == name }, "Нет свойства «\(name)»")
    }

    private func cell(_ row: Page, _ property: DatabaseProperty) throws -> JSONValue? {
        try read { try $0.cell(rowId: row.id, propertyId: property.id)?.value }
    }

    private func optionName(_ value: JSONValue?, of property: DatabaseProperty) throws -> String? {
        let options = try read { try $0.options(ofProperty: property.id) }
        return value?.string.flatMap { id in options.first { $0.id.uuidString.lowercased() == id }?.name }
    }

    private func bodyTexts(_ page: Page) throws -> [String] {
        try #require(try store.pageContent(page.id)).blocks.filter { $0.containerId == nil }.map(\.text.string)
    }

    private struct Imported {
        var owner: Page
        var tasks: Page
        var projects: Page
    }

    private func imported() throws -> (Imported, NotionImportReport) {
        let report = try runImport()
        let owner = try page("MyNotion — базы 004", parent: report.rootPageId)
        return (Imported(owner: owner, tasks: try page("Задачи", parent: owner.id), projects: try page("Проекты", parent: owner.id)), report)
    }

    // MARK: Место

    @Test("Ссылка на CSV в странице-хозяине — встроенная база на месте ссылки; без ссылки — полностраничная подстраница в конце")
    func placement() throws {
        let (db, _) = try imported()
        #expect(try read { try $0.database(db.tasks.id) }?.isInline == true)
        #expect(try read { try $0.database(db.projects.id) }?.isInline == false)
        let blocks = try #require(try store.pageContent(db.owner.id)).blocks
        #expect(blocks.map(\.kind) == [.paragraph, .database, .paragraph, .pageLink])
        #expect(blocks[1].linkedPageId == db.tasks.id)
        #expect(blocks[3].linkedPageId == db.projects.id)
        // У страницы-базы своих блоков нет — её содержимое строки; пустой абзац кладёт правило ядра, как у базы из «/».
        let databaseBlocks = try #require(try store.pageContent(db.tasks.id)).blocks
        #expect(databaseBlocks.allSatisfy { $0.kind == .paragraph && $0.text.string.isEmpty })
        #expect(try read { try $0.views(ofDatabase: db.tasks.id) }.map(\.name) == ["Таблица"])
    }

    // MARK: Строки ↔ файлы

    @Test("Строки — по порядку CSV, у каждой своё тело из `.md`; строки свойств отрезаны; одинаковые названия различает 32 hex")
    func rowsAndBodies() throws {
        let (db, _) = try imported()
        let rows = try rows(of: db.tasks.id)
        #expect(rows.map(\.title) == ["Купить молоко", "Купить молоко", "Позвонить в банк", ""])
        #expect(try bodyTexts(rows[0]) == ["Первое тело: жирный текст.", "пункт"])
        #expect(try bodyTexts(rows[1]) == ["Второе тело."])
        // Строка, похожая на свойство, но не из колонок, — тело.
        #expect(try bodyTexts(rows[2]).first == "Номер договора: 42 — это тело, не свойство.")
        let call = try page("Звонок", parent: rows[2].id)
        #expect(try bodyTexts(call) == ["Записи звонка."])
        // Одинаковые названия: строке со статусом «Готово» — файл со «Статус: Готово».
        let status = try property("Статус", of: db.tasks.id)
        #expect(try optionName(cell(rows[0], status), of: status) == "Готово")
        #expect(try optionName(cell(rows[1], status), of: status) == "В работе")
    }

    @Test("Файл строки, которой нет в CSV, — шаблон базы со своими значениями и телом")
    func templateFromUnmatchedFile() throws {
        let (db, report) = try imported()
        let template = try #require(try pages().first { $0.parentId == db.tasks.id && $0.isTemplate })
        #expect(template.title == "Новая задача")
        #expect(try bodyTexts(template) == ["Шаблонный текст."])
        let status = try property("Статус", of: db.tasks.id)
        #expect(try optionName(cell(template, status), of: status) == "В работе")
        #expect(report.databases.first { $0.title == "Задачи" }?.templateCount == 1)
    }

    // MARK: Типы

    @Test("Тип свойства угадан по всем значениям столбца — каждый признак таблицы contracts")
    func guessedTypes() throws {
        let (db, _) = try imported()
        let properties = try read { try $0.properties(ofDatabase: db.tasks.id) }
        let kinds = Dictionary(uniqueKeysWithValues: properties.map { ($0.name, $0.kind) })
        #expect(properties.map(\.name) == ["Name", "Статус", "Теги", "Срок", "Готово", "Часы", "Доля", "Сайт", "Почта", "Телефон", "ID",
                                           "Проект", "Итог", "Created time", "Last edited time", "Заметки", "Ответственный"])
        #expect(kinds == ["Name": .title, "Статус": .select, "Теги": .multiSelect, "Срок": .date, "Готово": .checkbox, "Часы": .number,
                          "Доля": .number, "Сайт": .url, "Почта": .email, "Телефон": .phone, "ID": .uniqueId, "Проект": .relation,
                          "Итог": .text, "Created time": .createdTime, "Last edited time": .lastEditedTime, "Заметки": .text,
                          "Ответственный": .text])
        #expect(try property("Доля", of: db.tasks.id).config["format"]?.string == "percent")
        // Варианты — в порядке первого появления, цвета Notion по кругу.
        let tagsProperty = try property("Теги", of: db.tasks.id)
        let tags = try read { try $0.options(ofProperty: tagsProperty.id) }
        #expect(tags.map(\.name) == ["Дом", "Срочно"])
        #expect(tags.map(\.color) == [OptionColor.allCases[0].rawValue, OptionColor.allCases[1].rawValue])
    }

    @Test("Значения ячеек по типам")
    func cellValues() throws {
        let (db, _) = try imported()
        let rows = try rows(of: db.tasks.id)
        let zone = TimeZone.current.identifier
        let due = try property("Срок", of: db.tasks.id)
        #expect(try cell(rows[0], due) == ["start": "2026-10-20", "hasTime": false, "timeZone": .string(zone)])
        #expect(try cell(rows[1], due) == ["start": "2026-10-21T15:15", "hasTime": true, "timeZone": .string(zone)])
        #expect(try cell(rows[2], due) == ["start": "2026-10-22", "end": "2026-10-24", "hasTime": false, "timeZone": .string(zone)])
        let tags = try property("Теги", of: db.tasks.id)
        #expect(try cell(rows[0], tags)?.array?.count == 2)
        #expect(try cell(rows[0], try property("Готово", of: db.tasks.id)) == .bool(true))
        #expect(try cell(rows[1], try property("Готово", of: db.tasks.id)) == .bool(false))
        #expect(try cell(rows[0], try property("Часы", of: db.tasks.id)) == .number(1.5))
        #expect(try cell(rows[2], try property("Часы", of: db.tasks.id)) == nil)
        #expect(try cell(rows[1], try property("Доля", of: db.tasks.id)) == .number(0.25))
        #expect(try cell(rows[1], try property("Сайт", of: db.tasks.id)) == "https://example.org/a?b=1")
        #expect(try cell(rows[0], try property("Телефон", of: db.tasks.id)) == "+7 (900) 123-45-67")
        #expect(try cell(rows[3], try property("ID", of: db.tasks.id)) == .number(4))
        #expect(try cell(rows[1], try property("Заметки", of: db.tasks.id))?["string"] == "Две строки\nзаметки")
        #expect(try cell(rows[0], try property("Итог", of: db.tasks.id))?["string"] == "Привет")
    }

    @Test("«Created time» и «Last edited time» — даты создания и правки строки")
    func pageTimes() throws {
        let (db, _) = try imported()
        let row = try rows(of: db.tasks.id)[0]
        let calendar = Calendar.current
        #expect(row.createdAt == calendar.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 9, minute: 0)))
        #expect(row.updatedAt == calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 18, minute: 30)))
    }

    @Test("Каждое непустое значение CSV перенесено (100 %)")
    func everyValueTransferred() throws {
        let (db, _) = try imported()
        let rows = try rows(of: db.tasks.id)
        let csv = try String(contentsOf: Self.synthetic.appendingPathComponent(
            "MyNotion — базы 004 a0000000000000000000000000000001/Задачи a0000000000000000000000000000002_all.csv"), encoding: .utf8)
        let table = NotionCSV.rows(csv)
        let header = table[0]
        for (column, name) in header.enumerated() where column > 0 {
            let property = try property(name, of: db.tasks.id)
            for (index, values) in table.dropFirst().enumerated() where !values[column].isEmpty {
                let present: Bool
                switch property.kind {
                case .createdTime, .lastEditedTime: present = true
                case .relation: present = try !read { try $0.relationLinks(propertyId: property.id, rowId: rows[index].id) }.isEmpty
                    || property.config["pairedPropertyId"] != nil
                default: present = try cell(rows[index], property) != nil
                }
                #expect(present, "«\(name)», строка \(index + 1): значение «\(values[column])» потеряно")
            }
        }
    }

    // MARK: Связи

    @Test("Связи по 32 hex; столбец-пара во второй базе — двусторонняя связь, записи — у свойства с меньшим id")
    func relations() throws {
        let (db, report) = try imported()
        let tasks = try rows(of: db.tasks.id)
        let projects = try rows(of: db.projects.id)
        #expect(projects.map(\.title) == ["Альфа", "Бета"])
        let taskProject = try property("Проект", of: db.tasks.id)
        let projectTasks = try property("Задачи", of: db.projects.id)
        #expect(taskProject.kind == .relation && projectTasks.kind == .relation)
        #expect(taskProject.config["targetDatabaseId"]?.string == db.projects.id.uuidString.lowercased())
        #expect(projectTasks.config["targetDatabaseId"]?.string == db.tasks.id.uuidString.lowercased())
        #expect(taskProject.config["pairedPropertyId"]?.string == projectTasks.id.uuidString.lowercased())
        #expect(projectTasks.config["pairedPropertyId"]?.string == taskProject.id.uuidString.lowercased())

        /// Связи строки задачи по свойству «Проект» — где бы они ни хранились.
        func linkedProjects(_ task: Page) throws -> [UUID] {
            if taskProject.id < projectTasks.id {
                return try read { try $0.relationLinks(propertyId: taskProject.id, rowId: task.id) }.map(\.targetRowId)
            }
            return try read { try $0.relationLinks(propertyId: projectTasks.id, targetRowId: task.id) }.map(\.rowId)
        }
        #expect(try linkedProjects(tasks[0]) == [projects[0].id])
        #expect(try Set(linkedProjects(tasks[1])) == [projects[0].id, projects[1].id])
        #expect(try linkedProjects(tasks[2]) == [projects[1].id])
        #expect(try linkedProjects(tasks[3]).isEmpty)
        let stored = max(taskProject.id, projectTasks.id)
        #expect(try read { try $0.relationLinks(propertyId: stored, rowId: projects[0].id) }.isEmpty)
        #expect(report.databases.first { $0.title == "Задачи" }?.properties.contains("Проект — связь с «Проекты», двусторонняя") == true)
    }

    // MARK: Отчёт

    @Test("Отчёт: по каждой базе — строки, шаблоны, угаданные типы; общие потери выгрузки Notion — дословно")
    func report() throws {
        let (_, report) = try imported()
        #expect(report.databases.map(\.title) == ["Задачи", "Проекты"])
        let tasks = try #require(report.databases.first)
        #expect(tasks.rowCount == 4)
        #expect(tasks.properties == [
            "Name — название", "Статус — выбор", "Теги — множественный выбор", "Срок — дата", "Готово — флажок", "Часы — число",
            "Доля — число (процент)", "Сайт — ссылка", "Почта — email", "Телефон — телефон", "ID — ID",
            "Проект — связь с «Проекты», двусторонняя", "Итог — текст", "Created time — создано", "Last edited time — изменено",
            "Заметки — текст", "Ответственный — текст",
        ])
        #expect(tasks.notes.isEmpty)
        #expect(report.notices.suffix(4) == [
            "Формулы и сводки Notion приходят готовыми значениями — числом или текстом",
            "Статусы Notion стали выбором: в выгрузке они неотличимы",
            "Цвета вариантов, виды, фильтры и сортировки в выгрузке Notion не передаются: цвета — по кругу, вид — один, «Таблица»",
            "Люди («Человек», «Создал», «Изменил») — текстом с именами",
        ])
        // Таблицы баз больше не упрощаются до абзацев.
        #expect(report.simplified.allSatisfy { !$0.items.contains("таблицы — по строке на абзац") })
    }

    // MARK: Без подстраниц

    @Test("Выгрузка без «Include subpages» (только два CSV): база со строками без тел и строка отчёта")
    func withoutSubpages() throws {
        let report = try runImport(Self.noSubpages)
        let contacts = try page("Контакты", parent: report.rootPageId)
        #expect(try read { try $0.database(contacts.id) }?.isInline == false)
        let rows = try rows(of: contacts.id)
        #expect(rows.map(\.title) == ["Аня", "Боря", "Вера", "Глеб"])
        #expect(try bodyTexts(rows[0]) == [""])
        #expect(try property("Город", of: contacts.id).kind == .select)
        #expect(try property("Сайт", of: contacts.id).kind == .url)
        let summary = try #require(report.databases.first)
        #expect(summary.notes == ["Выгрузка без подстраниц: у строк нет текста страниц"])
        // Видимые колонки — из CSV вида, остальные свойства скрыты.
        let view = try #require(try read { try $0.views(ofDatabase: contacts.id) }.first)
        let columns = try #require(view.columns.array)
        let names = Dictionary(uniqueKeysWithValues: try read { try $0.properties(ofDatabase: contacts.id) }
            .map { ($0.id.uuidString.lowercased(), $0.name) })
        #expect(columns.map { names[$0["propertyId"]?.string ?? ""] ?? "?" } == ["Name", "Город", "Сайт"])
        #expect(columns.map { $0["isVisible"]?.bool } == [true, true, false])
    }

    @Test("Та же выгрузка второй раз — новая база рядом, а не слияние")
    func secondImport() throws {
        try runImport(Self.noSubpages)
        try runImport(Self.noSubpages)
        let databases = try pages().filter { $0.title == "Контакты" }
        #expect(databases.count == 2)
        for database in databases { #expect(try rows(of: database.id).count == 4) }
    }

    @Test("Ошибка посреди импорта стирает ветку вместе с базами")
    func rollback() throws {
        let prepared = try NotionExportUnpacker().prepare(Self.synthetic)
        defer { prepared.discard() }
        var importer = NotionImporter(store: store, now: { [importDate] in importDate })
        importer.failAfterDatabaseRows = 2
        #expect(throws: (any Error).self) { try importer.importExport(prepared) }
        #expect(try pages().isEmpty)
        #expect(try store.write { tx throws in try tx.allDatabaseRecords() }.databases.isEmpty)
    }
}
