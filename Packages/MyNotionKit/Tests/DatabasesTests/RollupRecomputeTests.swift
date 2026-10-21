import Foundation
import Testing
@testable import Databases
@testable import Formulas
@testable import NotesCore

/// Сводки (T088, spec US4, research R8, contracts/property-types.md, «Итоги колонки и вычисления сводки»): каждое
/// вычисление по числу, дате, флажку, выбору, множественному выбору и названию; пересчёт той же записью при правке
/// значения цели, связи, корзине, возврате и стирании строки-цели; сводка по формуле и формула по сводке; новая сводка
/// и смена вычисления — в фоне.
@MainActor
@Suite("Сводки (US4)")
struct RollupRecomputeTests {
    let folder: URL
    let store: NotesStore
    let queue: FormulaRecomputeQueue
    let operations: DatabaseOperations
    let tasks: CreatedDatabase
    let projects: CreatedDatabase
    let hours: UUID, deadline: UUID, done: UUID, tags: UUID, status: UUID, relation: UUID, paired: UUID
    let taskRows: [UUID]
    let projectA: UUID, projectB: UUID
    let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("rollups-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = NotesStore(database: try AppDatabase.open(at: folder.appendingPathComponent("MyNotion.sqlite")), clock: HybridLogicalClock(deviceId: UUID()))
        queue = FormulaRecomputeQueue(store: store, calendar: utc)
        store.addWriteHook(CellIndexer())
        store.addWriteHook(ComputationHook(store: store, queue: queue, calendar: utc))
        operations = DatabaseOperations(store: store)
        tasks = try operations.createDatabase(in: nil, isInline: false, title: "Задачи")
        projects = try operations.createDatabase(in: nil, isInline: false, title: "Проекты")
        hours = try operations.addProperty(to: tasks.databaseId, name: "Часы", kind: .number).id
        deadline = try operations.addProperty(to: tasks.databaseId, name: "Срок", kind: .date).id
        done = try operations.addProperty(to: tasks.databaseId, name: "Сделано", kind: .checkbox).id
        tags = try operations.addProperty(to: tasks.databaseId, name: "Метки", kind: .multiSelect).id
        status = try operations.addProperty(to: tasks.databaseId, name: "Статус", kind: .select).id
        let created = try operations.addRelation(to: tasks.databaseId, name: "Проект", target: projects.databaseId, relatedName: "Задачи")
        relation = created.id
        paired = created.pairedRelation!
        let (tagsId, statusId) = (tags, status)
        let (urgent, home, ready, working) = try store.write { tx throws in
            func option(_ property: UUID, _ name: String, _ key: String) throws -> UUID {
                try tx.saveOption(SelectOption(propertyId: property, name: name, sortKey: FractionalSortKey(rawValue: key)!)).id
            }
            return (try option(tagsId, "Срочно", "a"), try option(tagsId, "Дом", "b"), try option(statusId, "Готово", "a"),
                    try option(statusId, "В работе", "b"))
        }
        func id(_ uuid: UUID) -> JSONValue { .string(uuid.databaseText) }
        func day(_ text: String) -> JSONValue { ["start": .string(text), "hasTime": false] }
        let rows: [(String, Double?, String?, Bool, [UUID], UUID?)] = [
            ("Позвонить", 2, "2026-10-21", true, [urgent, home], ready),
            ("Купить", 3.5, "2026-10-25", false, [home], ready),
            ("Сдать отчёт", nil, "2026-11-01", true, [], nil),
            ("Убрать", 4, nil, false, [urgent], working),
        ]
        var made: [UUID] = []
        for (title, number, date, flag, labels, option) in rows {
            let row = try operations.addRow(to: tasks.databaseId, in: nil, title: title)
            if let number { try operations.setCell(rowId: row, propertyId: hours, value: .number(number)) }
            if let date { try operations.setCell(rowId: row, propertyId: deadline, value: day(date)) }
            try operations.setCell(rowId: row, propertyId: done, value: .bool(flag))
            if !labels.isEmpty { try operations.setCell(rowId: row, propertyId: tags, value: .array(labels.map(id))) }
            if let option { try operations.setCell(rowId: row, propertyId: status, value: id(option)) }
            made.append(row)
        }
        taskRows = made
        projectA = try operations.addRow(to: projects.databaseId, in: nil, title: "Дом")
        projectB = try operations.addRow(to: projects.databaseId, in: nil, title: "Работа")
        for row in taskRows { try operations.linkRow(projectA, through: paired, to: row) }
    }

    func computed(_ row: UUID, _ property: UUID) throws -> JSONValue? {
        try store.database.dbWriter.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM db_computed WHERE rowId = ? AND propertyId = ?",
                                arguments: [row.databaseText, property.databaseText]).flatMap(FastJSON.parse)
        }
    }

    /// Новая сводка в «Проектах»; итоги — после фонового пересчёта.
    @discardableResult
    func addRollup(_ name: String, of target: UUID, _ calculation: Calculation) throws -> UUID {
        let property = try operations.addProperty(to: projects.databaseId, name: name, kind: .rollup)
        try operations.setRollup(property.id, relation: paired, target: target, calculation: calculation)
        queue.waitUntilIdle()
        return property.id
    }

    func value(of target: UUID, _ calculation: Calculation) throws -> JSONValue? {
        try computed(projectA, try addRollup("\(calculation)", of: target, calculation))
    }

    // MARK: Вычисления

    @Test("Число: как есть, уникальные, количество, пустые, проценты, сумма, среднее, медиана, мин, макс, размах")
    func numberCalculations() throws {
        let expected: [(Calculation, JSONValue?)] = [
            (.showOriginal, [2, 3.5, 4]), (.showUnique, [2, 3.5, 4]), (.countAll, 4), (.countValues, 3), (.countUnique, 3),
            (.countEmpty, 1), (.countNotEmpty, 3), (.percentEmpty, 0.25), (.percentNotEmpty, 0.75), (.sum, 9.5),
            (.average, .number((9.5 / 3 * 1e9).rounded() / 1e9)), (.median, 3.5), (.min, 2), (.max, 4), (.range, 2),
        ]
        for (calculation, value) in expected {
            let result = try self.value(of: hours, calculation)
            if case .number(let expectedNumber)? = value, case .number(let number)? = result {
                #expect(abs(number - expectedNumber) < 1e-6, "\(calculation)")
            } else {
                #expect(result == value, "\(calculation)")
            }
        }
        // Проекту без задач — пусто или ноль.
        let sum = try addRollup("Пусто", of: hours, .sum)
        #expect(try computed(projectB, sum) == nil)
        let count = try addRollup("Ноль", of: hours, .countAll)
        #expect(try computed(projectB, count) == 0)
    }

    @Test("Дата: ранняя, поздняя, диапазон в днях")
    func dateCalculations() throws {
        #expect(try value(of: deadline, .earliestDate)?["start"] == "2026-10-21")
        #expect(try value(of: deadline, .latestDate)?["start"] == "2026-11-01")
        #expect(try value(of: deadline, .dateRange) == 11)
    }

    @Test("Флажок: отмечено, не отмечено, проценты")
    func checkboxCalculations() throws {
        #expect(try value(of: done, .checked) == 2)
        #expect(try value(of: done, .unchecked) == 2)
        #expect(try value(of: done, .percentChecked) == 0.5)
        #expect(try value(of: done, .percentUnchecked) == 0.5)
    }

    @Test("Выбор, множественный выбор, название: показ — названиями, количество — по значениям")
    func optionAndTitleCalculations() throws {
        #expect(try value(of: status, .showOriginal) == ["Готово", "Готово", "В работе"])
        #expect(try value(of: status, .countUnique) == 2)
        #expect(try value(of: tags, .showUnique) == ["Срочно", "Дом"])
        #expect(try value(of: tags, .countValues) == 4)
        #expect(try value(of: tags, .countEmpty) == 1)
        let title = try #require(try store.write { try $0.properties(ofDatabase: tasks.databaseId) }.first { $0.kind == .title }).id
        #expect(try value(of: title, .showOriginal) == ["Позвонить", "Купить", "Сдать отчёт", "Убрать"])
    }

    @Test("Сводка по связи цели: как есть — плашки строк; показ процента — «50%»")
    func relationAndDisplay() throws {
        let unique = try value(of: relation, .showUnique)
        #expect(unique == [["id": .string(projectA.databaseText), "title": "Дом"]])
        let rollup = try addRollup("Доля", of: done, .percentChecked)
        let property = try #require(try store.write { try $0.property(rollup) })
        let context = PropertyContext(property: property, locale: Locale(identifier: "en_US_POSIX"))
        #expect(PropertyTypes.type(for: .rollup).displayText(.number(0.5), in: context) == "50%")
    }

    // MARK: Пересчёт

    @Test("Правка значения цели, снятие и новая связь — сводка пересчитана той же записью")
    func recomputeOnEdit() throws {
        let sum = try addRollup("Часы", of: hours, .sum)
        try operations.setCell(rowId: taskRows[1], propertyId: hours, value: .number(1.5))
        #expect(try computed(projectA, sum) == 7.5)
        try operations.unlinkRow(taskRows[0], through: relation, from: projectA)
        #expect(try computed(projectA, sum) == 5.5)
        try operations.linkRow(taskRows[0], through: relation, to: projectB)
        #expect(try computed(projectB, sum) == 2)
    }

    @Test("Строка-цель в корзину и обратно, стёрта навсегда — сводка пересчитана")
    func recomputeOnTrash() throws {
        let sum = try addRollup("Часы", of: hours, .sum)
        let count = try addRollup("Число", of: hours, .countAll)
        try operations.trashRows([taskRows[3]])
        #expect(try computed(projectA, sum) == 5.5)
        #expect(try computed(projectA, count) == 3)
        try operations.setRowsTrashed([taskRows[3]], false)
        #expect(try computed(projectA, sum) == 9.5)
        let tree = PageTreeOperations(store: store)
        try tree.moveToTrash(taskRows[0])
        try tree.deleteForever(taskRows[0])
        #expect(try computed(projectA, sum) == 7.5)
        #expect(try computed(projectA, count) == 3)
    }

    @Test("База-цель в корзину и обратно — сводки читающей базы пересчитаны в фоне")
    func recomputeOnDatabaseTrash() throws {
        let projectCount = try #require(try store.write { tx throws -> UUID in
            let last = try tx.properties(ofDatabase: tasks.databaseId, includingDeleted: true).map(\.sortKey).max()
            return try tx.saveProperty(DatabaseProperty(databaseId: tasks.databaseId, name: "Число проектов", kind: .rollup,
                                                        config: ["relationPropertyId": .string(relation.databaseText),
                                                                 "targetPropertyId": .string(projects.titlePropertyId.databaseText),
                                                                 "calculation": "countAll"], sortKey: .between(last, nil))).id
        })
        queue.waitUntilIdle()
        #expect(try computed(taskRows[0], projectCount) == 1)
        let tree = PageTreeOperations(store: store)
        try tree.moveToTrash(projects.databaseId)
        queue.waitUntilIdle()
        #expect(try computed(taskRows[0], projectCount) == 0)
        try tree.restore(projects.databaseId)
        queue.waitUntilIdle()
        #expect(try computed(taskRows[0], projectCount) == 1)
    }

    @Test("Сводка по формуле цели и формула по сводке — по цепочке той же записью")
    func formulaChain() throws {
        let doubled = try store.write { tx throws -> UUID in
            let last = try tx.properties(ofDatabase: tasks.databaseId, includingDeleted: true).map(\.sortKey).max()
            return try tx.saveProperty(DatabaseProperty(databaseId: tasks.databaseId, name: "Двойные", kind: .formula,
                                                        config: ["expression": .string(#"prop("\#(hours.databaseText)") * 2"#)],
                                                        sortKey: .between(last, nil))).id
        }
        queue.waitUntilIdle()
        let sum = try addRollup("Сумма двойных", of: doubled, .sum)
        #expect(try computed(projectA, sum) == 19)
        let plusOne = try store.write { tx throws -> UUID in
            let last = try tx.properties(ofDatabase: projects.databaseId, includingDeleted: true).map(\.sortKey).max()
            return try tx.saveProperty(DatabaseProperty(databaseId: projects.databaseId, name: "Итог", kind: .formula,
                                                        config: ["expression": .string(#"prop("\#(sum.databaseText)") + 1"#)],
                                                        sortKey: .between(last, nil))).id
        }
        queue.waitUntilIdle()
        #expect(try computed(projectA, plusOne) == 20)
        try operations.setCell(rowId: taskRows[0], propertyId: hours, value: .number(5))
        #expect(try computed(projectA, sum) == 25, "формула задачи, затем сводка проекта")
        #expect(try computed(projectA, plusOne) == 26, "затем формула проекта")
    }

    @Test("Смена вычисления и свойства цели — итоги всех строк в фоне; ⌘Z возвращает прежние")
    func configChange() throws {
        let undo = UndoManager()
        undo.groupsByEvent = false
        let edits = DatabaseOperations(store: store, undoManager: undo)
        let rollup = try addRollup("Итог", of: hours, .sum)
        undo.beginUndoGrouping()
        try edits.setRollup(rollup, relation: paired, target: hours, calculation: .max)
        undo.endUndoGrouping()
        queue.waitUntilIdle()
        #expect(try computed(projectA, rollup) == 4)
        undo.undo()
        queue.waitUntilIdle()
        #expect(try computed(projectA, rollup) == 9.5)
    }

    @Test("Первое заполнение: строки без итогов сводок досчитываются в фоне")
    func fillMissing() throws {
        let rollup = try addRollup("Часы", of: hours, .sum)
        try store.database.dbWriter.write { db in try db.execute(sql: "DELETE FROM db_computed WHERE propertyId = ?", arguments: [rollup.databaseText]) }
        queue.fillMissing()
        queue.waitUntilIdle()
        queue.waitUntilIdle()
        #expect(try computed(projectA, rollup) == 9.5)
    }
}
