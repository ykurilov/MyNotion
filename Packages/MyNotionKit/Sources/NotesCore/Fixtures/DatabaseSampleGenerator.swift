import Foundation
import GRDB

/// Эталон баз для проб и замеров 004 (quickstart.md, «Эталон», дополнения 004): «Задачи» — 10 000 строк × 30 свойств всех
/// 18 типов, «Проекты» — 500 строк с двусторонней связью, «Обзор» со встроенной базой на 10 000 строк и 200 блоками текста,
/// вид «Задачи — работа». Пишет записи прямо в таблицы одной транзакцией, без операций и подписчиков, вместе со
/// сравнимыми колонками и итогами формул и сводок, — как их запишут подписчики модуля `Databases` (для проб этапа 0).
/// Содержимое одинаково при каждом запуске (постоянное зерно); даты — от сегодняшнего дня.
public struct DatabaseSampleGenerator: Sendable {
    public static let taskCount = 10_000
    public static let projectCount = 500
    public static let overviewBlockCount = 200
    public static let optionsPerSelect = 12
    public static let tasksTitle = "Задачи"
    public static let projectsTitle = "Проекты"
    public static let overviewTitle = "Обзор"
    public static let inlineTasksTitle = "Задачи (встроенная)"
    public static let workViewName = "Задачи — работа"

    /// Что создано: id для проб.
    public struct Sample: Sendable {
        public var tasksId: UUID
        public var projectsId: UUID
        public var overviewId: UUID
        public var inlineTasksId: UUID
        public var workViewId: UUID
        public var tableViewId: UUID
        public var inlineViewId: UUID
        /// Свойства «Задач» по названию; у встроенной базы — свои id с теми же названиями.
        public var taskProperties: [String: UUID]
        public var inlineTaskProperties: [String: UUID]
        public var projectProperties: [String: UUID]
        /// Варианты по свойству и названию.
        public var options: [UUID: [String: UUID]]
    }

    private let seed: UInt64
    private let taskCount: Int
    private let projectCount: Int

    public init(seed: UInt64 = 20_261_021, taskCount: Int = Self.taskCount, projectCount: Int = Self.projectCount) {
        self.seed = seed
        self.taskCount = taskCount
        self.projectCount = projectCount
    }

    /// Найти уже созданный эталон в хранилище.
    public static func existing(in store: NotesStore) throws -> Sample? {
        try store.database.dbWriter.read { db in
            guard let tasks = try pageId(titled: tasksTitle, in: db), let projects = try pageId(titled: projectsTitle, in: db),
                  let overview = try pageId(titled: overviewTitle, in: db), let inline = try pageId(titled: inlineTasksTitle, in: db) else { return nil }
            func properties(_ databaseId: UUID) throws -> [String: UUID] {
                Dictionary(try Row.fetchAll(db, sql: "SELECT id, name FROM db_property WHERE databaseId = ?", arguments: [databaseId.databaseText])
                    .map { ($0["name"] as String, UUID(uuidString: $0["id"])!) }, uniquingKeysWith: { first, _ in first })
            }
            func view(_ databaseId: UUID, _ name: String) throws -> UUID? {
                try String.fetchOne(db, sql: "SELECT id FROM db_view WHERE databaseId = ? AND name = ?", arguments: [databaseId.databaseText, name])
                    .flatMap(UUID.init(uuidString:))
            }
            var options: [UUID: [String: UUID]] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT id, propertyId, name FROM db_select_option") {
                options[UUID(uuidString: row["propertyId"])!, default: [:]][row["name"]] = UUID(uuidString: row["id"])!
            }
            guard let work = try view(tasks, workViewName), let table = try view(tasks, "Таблица"), let inlineView = try view(inline, "Таблица")
            else { return nil }
            return Sample(tasksId: tasks, projectsId: projects, overviewId: overview, inlineTasksId: inline, workViewId: work,
                          tableViewId: table, inlineViewId: inlineView, taskProperties: try properties(tasks),
                          inlineTaskProperties: try properties(inline), projectProperties: try properties(projects), options: options)
        }
    }

    private static func pageId(titled title: String, in db: Database) throws -> UUID? {
        try String.fetchOne(db, sql: "SELECT page.id FROM page JOIN db_database ON db_database.pageId = page.id WHERE page.title = ?",
                            arguments: [title]).flatMap(UUID.init(uuidString:))
            ?? (title == overviewTitle ? String.fetchOne(db, sql: "SELECT id FROM page WHERE title = ? AND parentId IS NULL", arguments: [title])
                .flatMap(UUID.init(uuidString:)) : nil)
    }

    /// Записать эталон баз в новый файл `url`; `base` — копия какой базы дополняется (эталон 001–003), без неё — пустая.
    /// Сначала во временный файл рядом: прерванная генерация не оставит половину эталона.
    public func generate(at url: URL, base: URL? = nil) throws {
        let draftURL = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).draft-\(UUID().uuidString)")
        defer {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: draftURL.path + suffix) }
        }
        if let base { try FileManager.default.copyItem(at: base, to: draftURL) }
        let database = try AppDatabase.open(at: draftURL)
        try ensure(in: NotesStore(database: database, clock: HybridLogicalClock(deviceId: UUID())))
        try database.dbWriter.writeWithoutTransaction { try $0.checkpoint(.truncate) }
        database.close()
        try FileManager.default.moveItem(at: draftURL, to: url)
    }

    /// Дополнить хранилище эталоном баз (если его ещё нет) и вернуть id.
    @discardableResult
    public func ensure(in store: NotesStore) throws -> Sample {
        if let sample = try Self.existing(in: store) { return sample }
        return try store.write { transaction in
            var writer = Writer(seed: seed, transaction: transaction, taskCount: taskCount, projectCount: projectCount)
            return try writer.write()
        }
    }
}

// MARK: Запись

private struct Writer {
    let transaction: NotesTransaction
    let db: Database
    let stamp: HybridTimestamp
    let now = Date()
    let today: Date
    let calendar = Calendar(identifier: .gregorian)
    let timeZone = TimeZone.current.identifier
    let taskCount: Int
    let projectCount: Int
    var random: SeededRandom
    var sample: DatabaseSampleGenerator.Sample

    init(seed: UInt64, transaction: NotesTransaction, taskCount: Int, projectCount: Int) {
        self.transaction = transaction
        db = transaction.database
        stamp = transaction.clock.now()
        today = Calendar(identifier: .gregorian).startOfDay(for: Date())
        self.taskCount = taskCount
        self.projectCount = projectCount
        random = SeededRandom(seed: seed)
        sample = DatabaseSampleGenerator.Sample(tasksId: UUID(), projectsId: UUID(), overviewId: UUID(), inlineTasksId: UUID(),
                                                workViewId: UUID(), tableViewId: UUID(), inlineViewId: UUID(), taskProperties: [:],
                                                inlineTaskProperties: [:], projectProperties: [:], options: [:])
    }

    /// Свойства «Задач»: 30 штук всех 18 типов (quickstart.md).
    static let taskSchema: [(String, PropertyKind)] = [
        ("Название", .title), ("Описание", .text), ("Заметка", .text), ("Часы", .number), ("Оценка", .number),
        ("Приоритет", .select), ("Область", .select), ("Теги", .multiSelect), ("Метки", .multiSelect), ("Статус", .status),
        ("Срок", .date), ("Начало", .date), ("Сделано", .checkbox), ("Важно", .checkbox), ("Проверено", .checkbox),
        ("Ссылка", .url), ("Документ", .url), ("Почта", .email), ("Копия", .email), ("Телефон", .phone), ("Рабочий", .phone),
        ("Файлы", .files), ("Создано", .createdTime), ("Изменено", .lastEditedTime), ("Проект", .relation), ("Срок проекта", .rollup),
        ("Дней до срока", .formula), ("Итог", .formula), ("Проект (имя)", .formula), ("ID", .uniqueId),
    ]

    static let statusOptions: [(String, OptionColor, StatusGroup)] = [
        ("Не начато", .default, .todo), ("Отложено", .gray, .todo), ("В работе", .blue, .inProgress),
        ("На проверке", .purple, .inProgress), ("Готово", .green, .complete), ("Отменено", .red, .complete),
    ]

    static let words = ["отчёт", "встреча", "звонок", "договор", "план", "бюджет", "заявка", "сайт", "письмо", "обзор", "macOS",
                        "релиз", "дизайн", "тест", "счёт", "поставка", "ремонт", "запуск", "Ёлка", "архив", "Notion", "review"]

    mutating func write() throws -> DatabaseSampleGenerator.Sample {
        let rootKey = try String.fetchOne(db, sql: "SELECT MAX(sortKey) FROM page WHERE parentId IS NULL").flatMap(FractionalSortKey.init(rawValue:))
        let projectsKey = FractionalSortKey.between(rootKey, nil)
        let tasksKey = FractionalSortKey.between(projectsKey, nil)
        let overviewKey = FractionalSortKey.between(tasksKey, nil)

        sample.projectsId = try insertPage(DatabaseSampleGenerator.projectsTitle, icon: "🗂️", parent: nil, sortKey: projectsKey, withBlock: false)
        sample.tasksId = try insertPage(DatabaseSampleGenerator.tasksTitle, icon: "✅", parent: nil, sortKey: tasksKey, withBlock: false)
        sample.overviewId = try insertPage(DatabaseSampleGenerator.overviewTitle, icon: "📊", parent: nil, sortKey: overviewKey, withBlock: false)
        sample.inlineTasksId = try insertPage(DatabaseSampleGenerator.inlineTasksTitle, icon: nil, parent: sample.overviewId,
                                              sortKey: .between(nil, nil), withBlock: false)

        // Проекты: Название, Задачи (пара связи «Проект»), Срок, Число задач, Сумма часов.
        try insertDatabase(sample.projectsId, isInline: false)
        var projectProperties: [String: UUID] = [:]
        var key: FractionalSortKey?
        // id связи «Проект» меньше id «Задачи» (создаётся раньше): связи хранятся у него (data-model.md, `db_relation_link`).
        let taskRelationId = UUID.timeOrdered()
        let projectRelationId = UUID.timeOrdered()
        for (name, kind, id) in [("Название", PropertyKind.title, UUID.timeOrdered()), ("Задачи", .relation, projectRelationId),
                                 ("Срок", .date, UUID.timeOrdered()), ("Число задач", .rollup, UUID.timeOrdered()),
                                 ("Сумма часов", .rollup, UUID.timeOrdered())] {
            key = .between(key, nil)
            projectProperties[name] = id
            try insertProperty(DatabaseProperty(id: id, databaseId: sample.projectsId, name: name, kind: kind, sortKey: key!))
        }
        sample.projectProperties = projectProperties

        var projectRows: [UUID] = []
        var projectTitles: [String] = []
        var projectDeadlines: [Date] = []
        key = nil
        for index in 0..<projectCount {
            key = .between(key, nil)
            let title = "Проект \(index + 1): \(Self.words[index % Self.words.count])"
            let row = try insertPage(title, icon: nil, parent: sample.projectsId, sortKey: key!, withBlock: true)
            projectRows.append(row)
            projectTitles.append(title)
            let deadline = calendar.date(byAdding: .day, value: Int.random(in: -30...120, using: &random), to: today)!
            projectDeadlines.append(deadline)
            try insertCell(row, projectProperties["Срок"]!, dateValue(deadline, hasTime: false), number: deadline.timeIntervalSince1970)
            try insertComputed(row, projectProperties["Название"]!, value: nil, text: title)
        }

        let tasks = try writeTasks(database: sample.tasksId, isInline: false, relation: (taskRelationId, projectRelationId),
                                   projectRows: projectRows, projectTitles: projectTitles, projectDeadlines: projectDeadlines)
        sample.taskProperties = tasks.properties
        sample.workViewId = tasks.workView
        sample.tableViewId = tasks.tableView
        // Конфигурации связи и сводок — когда известны id обеих сторон.
        try updateConfig(projectRelationId, ["targetDatabaseId": .string(sample.tasksId.databaseText), "limit": "none",
                                             "pairedPropertyId": .string(taskRelationId.databaseText)])
        try updateConfig(projectProperties["Число задач"]!, ["relationPropertyId": .string(projectRelationId.databaseText),
                                                             "targetPropertyId": .string(tasks.properties["Название"]!.databaseText),
                                                             "calculation": "countAll"])
        try updateConfig(projectProperties["Сумма часов"]!, ["relationPropertyId": .string(projectRelationId.databaseText),
                                                             "targetPropertyId": .string(tasks.properties["Часы"]!.databaseText),
                                                             "calculation": "sum"])
        for (index, row) in projectRows.enumerated() {
            let count = tasks.projectTaskCounts[index]
            let hours = tasks.projectHours[index]
            try insertComputed(row, projectProperties["Число задач"]!, value: .number(Double(count)), number: Double(count))
            try insertComputed(row, projectProperties["Сумма часов"]!, value: .number(hours), number: hours)
        }
        for view in [("Таблица", true)] {
            try insertView(DatabaseView(databaseId: sample.projectsId, name: view.0, sortKey: .between(nil, nil),
                                        layoutOptions: ["openRowsIn": "sidePeek", "loadLimit": 50, "wrapAllContent": false]))
        }

        // «Обзор»: 200 блоков текста, встроенная база посередине.
        var blockKey: FractionalSortKey?
        for index in 0..<DatabaseSampleGenerator.overviewBlockCount {
            if index == DatabaseSampleGenerator.overviewBlockCount / 2 {
                blockKey = .between(blockKey, nil)
                try insertBlock(Block(pageId: sample.overviewId, kind: .database, linkedPageId: sample.inlineTasksId, sortKey: blockKey!))
            }
            blockKey = .between(blockKey, nil)
            let kind: BlockKind = index % 25 == 0 ? .heading2 : .paragraph
            let text = kind == .heading2 ? "Раздел \(index / 25 + 1)" : "Абзац \(index + 1) обзора: \(Self.words[index % Self.words.count]) и ещё немного текста вокруг базы."
            try insertBlock(Block(pageId: sample.overviewId, kind: kind, text: InlineText(text), sortKey: blockKey!))
        }
        let inline = try writeTasks(database: sample.inlineTasksId, isInline: true, relation: nil, projectRows: projectRows,
                                    projectTitles: projectTitles, projectDeadlines: projectDeadlines)
        sample.inlineTaskProperties = inline.properties
        sample.inlineViewId = inline.tableView
        return sample
    }

    struct WrittenTasks {
        var properties: [String: UUID]
        var workView: UUID
        var tableView: UUID
        var projectTaskCounts: [Int]
        var projectHours: [Double]
    }

    /// База задач: свойства, варианты, строки со значениями, итоги, виды. `relation` — свойства пары; у встроенной копии
    /// связь односторонняя (на те же «Проекты»).
    mutating func writeTasks(database: UUID, isInline: Bool, relation: (task: UUID, project: UUID)?, projectRows: [UUID],
                             projectTitles: [String], projectDeadlines: [Date]) throws -> WrittenTasks {
        try insertDatabase(database, isInline: isInline)
        var ids: [String: UUID] = [:]
        var key: FractionalSortKey?
        for (name, kind) in Self.taskSchema {
            key = .between(key, nil)
            let id = name == "Проект" ? (relation?.task ?? UUID.timeOrdered()) : UUID.timeOrdered()
            ids[name] = id
            var config: JSONValue = .emptyObject
            switch name {
            case "Часы": config = ["format": "number", "decimals": "auto", "showAs": "number"]
            case "Оценка": config = ["format": "number", "decimals": 0, "showAs": ["kind": "bar", "color": "green", "divideBy": 10, "showNumber": true]]
            case "Срок", "Начало": config = ["dateFormat": "full", "timeFormat": "h24"]
            case "Проект":
                config = ["targetDatabaseId": .string(sample.projectsId.databaseText), "limit": "one"]
                if let relation { config["pairedPropertyId"] = .string(relation.project.databaseText) }
            case "ID": config = ["prefix": "ЗАД"]
            case "Статус":
                config = ["groups": [["id": "todo", "name": "К выполнению", "color": "gray"], ["id": "inProgress", "name": "В работе", "color": "blue"],
                                     ["id": "complete", "name": "Завершено", "color": "green"]]]
            default: break
            }
            try insertProperty(DatabaseProperty(id: id, databaseId: database, name: name, kind: kind, config: config, sortKey: key!))
        }
        try updateConfig(ids["Срок проекта"]!, ["relationPropertyId": .string(ids["Проект"]!.databaseText),
                                                 "targetPropertyId": .string(sample.projectProperties["Срок"]!.databaseText),
                                                 "calculation": "earliestDate"])
        try updateConfig(ids["Дней до срока"]!, ["expression": .string(#"dateBetween(prop("\#(ids["Срок"]!.databaseText)"), now(), "days")"#)])
        try updateConfig(ids["Итог"]!, ["expression": .string(#"if(prop("\#(ids["Сделано"]!.databaseText)"), "Готово", "В работе")"#)])
        try updateConfig(ids["Проект (имя)"]!, ["expression": .string(
            #"prop("\#(ids["Проект"]!.databaseText)").map(current.prop("\#(sample.projectProperties["Название"]!.databaseText)"))"#)])

        // Варианты: по 12 у выбора и множественного выбора, 6 у статуса.
        var options: [String: [(id: UUID, name: String)]] = [:]
        let colors = OptionColor.allCases
        for name in ["Приоритет", "Область", "Теги", "Метки"] {
            var optionKey: FractionalSortKey?
            var list: [(UUID, String)] = []
            for index in 0..<DatabaseSampleGenerator.optionsPerSelect {
                optionKey = .between(optionKey, nil)
                let optionName = name == "Теги" && index == 0 ? "Срочно" : "\(name) \(index + 1)"
                let option = SelectOption(propertyId: ids[name]!, name: optionName, color: colors[(index + 1) % colors.count], sortKey: optionKey!)
                try insertOption(option)
                list.append((option.id, optionName))
            }
            options[name] = list
            sample.options[ids[name]!] = Dictionary(uniqueKeysWithValues: list.map { ($0.1, $0.0) })
        }
        var statusKey: FractionalSortKey?
        var statusList: [(UUID, String)] = []
        for (name, color, group) in Self.statusOptions {
            statusKey = .between(statusKey, nil)
            let option = SelectOption(propertyId: ids["Статус"]!, name: name, color: color, sortKey: statusKey!, statusGroup: group)
            try insertOption(option)
            statusList.append((option.id, name))
        }
        options["Статус"] = statusList
        sample.options[ids["Статус"]!] = Dictionary(uniqueKeysWithValues: statusList.map { ($0.1, $0.0) })

        var counts = Array(repeating: 0, count: projectRows.count)
        var hours = Array(repeating: 0.0, count: projectRows.count)
        var rowKey: FractionalSortKey?
        for index in 0..<taskCount {
            rowKey = .between(rowKey, nil)
            let word = Self.words[Int.random(in: 0..<Self.words.count, using: &random)]
            let title = "Задача \(index + 1): \(word) \(Self.words[(index * 7) % Self.words.count])"
            let hasBody = index % 5 == 0
            let row = try insertPage(title, icon: index % 17 == 0 ? "📌" : nil, parent: database, sortKey: rowKey!, withBlock: !hasBody)
            if hasBody {
                var bodyKey: FractionalSortKey?
                for line in 1...5 {
                    bodyKey = .between(bodyKey, nil)
                    try insertBlock(Block(pageId: row, kind: line == 1 ? .heading3 : .paragraph,
                                          text: InlineText(line == 1 ? "Подробности" : "Шаг \(line - 1): \(word), проверить и записать итог."),
                                          sortKey: bodyKey!))
                }
            }
            try insertComputed(row, ids["Название"]!, value: nil, text: title)
            try insertText(row, ids["Описание"]!, "Описание \(index + 1): \(word) для \(Self.words[(index * 3) % Self.words.count])")
            if index % 3 == 0 { try insertText(row, ids["Заметка"]!, "Заметка к задаче \(index + 1)") }
            let taskHours = Double(Int.random(in: 1...80, using: &random)) / 2
            try insertCell(row, ids["Часы"]!, .number(taskHours), number: taskHours)
            let score = Double(Int.random(in: 1...10, using: &random))
            try insertCell(row, ids["Оценка"]!, .number(score), number: score)
            for name in ["Приоритет", "Область"] {
                let position = Int.random(in: 0..<DatabaseSampleGenerator.optionsPerSelect, using: &random)
                try insertOptionCell(row, ids[name]!, options[name]![position], position: position)
            }
            for name in ["Теги", "Метки"] {
                let count = Int.random(in: 0...3, using: &random)
                var positions = Set<Int>()
                while positions.count < count { positions.insert(Int.random(in: 0..<DatabaseSampleGenerator.optionsPerSelect, using: &random)) }
                if !positions.isEmpty {
                    let sorted = positions.sorted()
                    let chosen = sorted.map { options[name]![$0] }
                    try insertCell(row, ids[name]!, .array(chosen.map { .string($0.id.databaseText) }), text: chosen.map(\.id.databaseText).joined(separator: " "),
                                   number: Double(sorted[0]), search: SortableText.make(chosen.map(\.name).joined(separator: " ")))
                }
            }
            let statusPosition = Int.random(in: 0..<Self.statusOptions.count, using: &random)
            try insertOptionCell(row, ids["Статус"]!, statusList[statusPosition], position: statusPosition)
            let deadline = calendar.date(byAdding: .day, value: Int.random(in: -40...60, using: &random), to: today)!
            try insertCell(row, ids["Срок"]!, dateValue(deadline, hasTime: false), number: deadline.timeIntervalSince1970)
            if index % 2 == 0 {
                let start = calendar.date(byAdding: .minute, value: -Int.random(in: 60...20_000, using: &random) * 10, to: deadline)!
                try insertCell(row, ids["Начало"]!, dateValue(start, hasTime: true), number: start.timeIntervalSince1970)
            }
            let done = random.chance(0.3)
            try insertCell(row, ids["Сделано"]!, .bool(done), number: done ? 1 : 0)
            for name in ["Важно", "Проверено"] where random.chance(0.2) { try insertCell(row, ids[name]!, .bool(true), number: 1) }
            if index % 4 == 0 { try insertPlain(row, ids["Ссылка"]!, "https://example.com/tasks/\(index + 1)") }
            if index % 9 == 0 { try insertPlain(row, ids["Документ"]!, "https://docs.example.com/\(word)/\(index)") }
            if index % 6 == 0 { try insertPlain(row, ids["Почта"]!, "user\(index % 97)@example.com") }
            if index % 11 == 0 { try insertPlain(row, ids["Копия"]!, "copy\(index % 13)@example.org") }
            if index % 8 == 0 { try insertPlain(row, ids["Телефон"]!, "+7 900 \(100 + index % 900) \(10 + index % 90) \(10 + index % 89)") }
            if index % 15 == 0 { try insertPlain(row, ids["Рабочий"]!, "+7 495 \(200 + index % 700)-\(10 + index % 90)-\(10 + index % 89)") }
            if index % 20 == 0 {
                try insertCell(row, ids["Файлы"]!, [["url": .string("https://example.com/files/\(index).pdf"), "name": .string("Файл \(index).pdf")]],
                               text: SortableText.make("Файл \(index).pdf"), number: 1, search: SortableText.make("Файл \(index).pdf"))
            }
            try insertCell(row, ids["ID"]!, .number(Double(index + 1)), number: Double(index + 1), search: "зад-\(index + 1)")

            // Связь с проектом (в среднем 20 задач на проект) и итоги, как их посчитают формулы и сводки.
            let project = index % projectRows.count
            let link = RelationLink(propertyId: ids["Проект"]!, rowId: row, targetRowId: projectRows[project], sortKey: .between(nil, nil))
            try insertLink(link)
            counts[project] += 1
            hours[project] += taskHours
            let projectDeadline = projectDeadlines[project]
            try insertComputed(row, ids["Срок проекта"]!, value: dateValue(projectDeadline, hasTime: false), number: projectDeadline.timeIntervalSince1970)
            let days = Double(calendar.dateComponents([.day], from: now, to: deadline).day ?? 0)
            try insertComputed(row, ids["Дней до срока"]!, value: .number(days), number: days)
            try insertComputed(row, ids["Итог"]!, value: .string(done ? "Готово" : "В работе"), text: done ? "Готово" : "В работе")
            try insertComputed(row, ids["Проект (имя)"]!, value: .array([.string(projectTitles[project])]), text: projectTitles[project])
        }

        // Виды: «Таблица» — все свойства по порядку; «Задачи — работа» — фильтр, сортировки, группа, 10 скрытых свойств.
        let tableView = DatabaseView(databaseId: database, name: "Таблица", sortKey: .between(nil, nil),
                                     columns: .array(Self.taskSchema.map { ["propertyId": .string(ids[$0.0]!.databaseText), "isVisible": true, "width": 200] }),
                                     layoutOptions: ["openRowsIn": "sidePeek", "loadLimit": 50, "wrapAllContent": false])
        try insertView(tableView)
        guard !isInline else {
            return WrittenTasks(properties: ids, workView: tableView.id, tableView: tableView.id, projectTaskCounts: counts, projectHours: hours)
        }
        let hidden: Set<String> = ["Заметка", "Метки", "Важно", "Проверено", "Документ", "Копия", "Рабочий", "Файлы", "Начало", "Проект (имя)"]
        let doneId = options["Статус"]!.first { $0.name == "Готово" }!.id
        let urgentId = options["Теги"]![0].id
        let filter: JSONValue = ["and": [
            ["propertyId": .string(ids["Статус"]!.databaseText), "operator": "isNot", "value": [.string(doneId.databaseText)]],
            ["or": [
                ["propertyId": .string(ids["Срок"]!.databaseText), "operator": "isRelativeToToday",
                 "value": ["direction": "this", "count": 1, "unit": "week"]],
                ["propertyId": .string(ids["Теги"]!.databaseText), "operator": "contains", "value": [.string(urgentId.databaseText)]],
            ]],
        ]]
        let workView = DatabaseView(databaseId: database, name: DatabaseSampleGenerator.workViewName, sortKey: .between(tableView.sortKey, nil),
                                    filter: filter,
                                    sorts: [["propertyId": .string(ids["Дней до срока"]!.databaseText), "direction": "ascending"],
                                            ["propertyId": .string(ids["Название"]!.databaseText), "direction": "ascending"]],
                                    columns: .array(Self.taskSchema.map {
                                        ["propertyId": .string(ids[$0.0]!.databaseText), "isVisible": .bool(!hidden.contains($0.0)), "width": 180]
                                    }),
                                    group: ["propertyId": .string(ids["Статус"]!.databaseText), "groupSort": "manual", "groups": [], "hideEmpty": true],
                                    layoutOptions: ["openRowsIn": "sidePeek", "loadLimit": 50, "wrapAllContent": false])
        try insertView(workView)
        return WrittenTasks(properties: ids, workView: workView.id, tableView: tableView.id, projectTaskCounts: counts, projectHours: hours)
    }

    // MARK: Строки таблиц

    func dateValue(_ date: Date, hasTime: Bool) -> JSONValue {
        var components = calendar.dateComponents(in: TimeZone.current, from: date)
        components.nanosecond = 0
        let day = String(format: "%04d-%02d-%02d", components.year!, components.month!, components.day!)
        let start = hasTime ? day + String(format: "T%02d:%02d", components.hour!, components.minute!) : day
        return ["start": .string(start), "hasTime": .bool(hasTime), "timeZone": .string(timeZone)]
    }

    func insertPage(_ title: String, icon: String?, parent: UUID?, sortKey: FractionalSortKey, withBlock: Bool) throws -> UUID {
        var clocks = PageFieldClocks()
        clocks.stamp(Set(Page.Field.allCases), with: stamp)
        let page = Page(title: title, icon: icon, parentId: parent, sortKey: sortKey, createdAt: now, updatedAt: now, fieldClocks: clocks)
        try page.insert(into: db)
        if withBlock { try insertBlock(Block(pageId: page.id, sortKey: .between(nil, nil))) }
        return page.id
    }

    func insertBlock(_ block: Block) throws {
        var block = block
        block.fieldClocks.stamp(Set(Block.Field.allCases).subtracting([.deleted]), with: stamp)
        block.textBaseClock = stamp
        try block.insert(into: db)
    }

    func insertDatabase(_ pageId: UUID, isInline: Bool) throws {
        try DatabaseSchema(pageId: pageId, isInline: isInline, fieldClocks: RecordClocks(Dictionary(uniqueKeysWithValues:
            DatabaseSchema.Field.allCases.map { ($0, stamp) }))).save(in: db)
    }

    func insertProperty(_ property: DatabaseProperty) throws {
        var property = property
        property.fieldClocks.stamp(Set(DatabaseProperty.Field.allCases), with: stamp)
        try property.save(in: db)
    }

    func updateConfig(_ propertyId: UUID, _ config: JSONValue) throws {
        try db.execute(sql: "UPDATE db_property SET config = ? WHERE id = ?", arguments: [config.jsonText, propertyId.databaseText])
    }

    func insertOption(_ option: SelectOption) throws {
        var option = option
        option.fieldClocks.stamp(Set(SelectOption.Field.allCases), with: stamp)
        try option.save(in: db)
    }

    func insertView(_ view: DatabaseView) throws {
        var view = view
        view.fieldClocks.stamp(Set(DatabaseView.Field.allCases), with: stamp)
        try view.save(in: db)
    }

    func insertLink(_ link: RelationLink) throws {
        var link = link
        link.fieldClocks.stamp(Set(RelationLink.Field.allCases), with: stamp)
        try link.save(in: db)
    }

    func insertText(_ row: UUID, _ property: UUID, _ text: String) throws {
        try insertCell(row, property, try JSONValue(encoding: InlineText(text)), text: SortableText.make(text), search: SortableText.make(text))
    }

    func insertPlain(_ row: UUID, _ property: UUID, _ text: String) throws {
        try insertCell(row, property, .string(text), text: SortableText.make(text), search: SortableText.make(text))
    }

    func insertOptionCell(_ row: UUID, _ property: UUID, _ option: (id: UUID, name: String), position: Int) throws {
        try insertCell(row, property, .string(option.id.databaseText), text: option.id.databaseText, number: Double(position),
                       search: SortableText.make(option.name))
    }

    func insertCell(_ row: UUID, _ property: UUID, _ value: JSONValue, text: String? = nil, number: Double? = nil, search: String? = nil) throws {
        try db.cachedStatement(sql: "INSERT INTO db_cell (rowId, propertyId, value, hlc, sortText, sortNumber, searchText) VALUES (?, ?, ?, ?, ?, ?, ?)")
            .execute(arguments: [row.databaseText, property.databaseText, value.jsonText, stamp.description, text, number, search])
    }

    func insertComputed(_ row: UUID, _ property: UUID, value: JSONValue?, text: String? = nil, number: Double? = nil) throws {
        let sortText = text.map(SortableText.make)
        try db.cachedStatement(sql: "INSERT INTO db_computed (rowId, propertyId, value, sortText, sortNumber, searchText) VALUES (?, ?, ?, ?, ?, ?)")
            .execute(arguments: [row.databaseText, property.databaseText, value?.jsonText, sortText, number, sortText])
    }
}
