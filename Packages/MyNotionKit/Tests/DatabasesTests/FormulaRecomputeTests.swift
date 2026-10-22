import Foundation
import Formulas
import GRDB
import Testing
import Synchronization
@testable import Databases
@testable import NotesCore

/// Пересчёт формул в базе (contracts/formulas.md, «Пересчёт», research R21): правка значения пересчитывает зависящие
/// формулы своей строки и связанных строк в той же транзакции; полный пересчёт — в фоне пачками, до готовности — прежний
/// итог; переименование свойства формул не ломает; «живые» формулы — раз в минуту только у открытого вида.
@Suite("Пересчёт формул в базе")
struct FormulaRecomputeTests {
    let folder: URL
    let store: NotesStore
    let sample: DatabaseSampleGenerator.Sample
    let clock = TestClock()
    let queue: FormulaRecomputeQueue

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("formula-recompute-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = NotesStore(database: try AppDatabase.open(at: folder.appendingPathComponent("MyNotion.sqlite")), clock: HybridLogicalClock(deviceId: UUID()))
        sample = try DatabaseSampleGenerator(taskCount: 120, projectCount: 8).ensure(in: store)
        let clock = self.clock
        queue = FormulaRecomputeQueue(store: store, now: { clock.now })
        store.addWriteHook(CellIndexer())
        store.addWriteHook(ComputationHook(store: store, queue: queue, now: { clock.now }))
    }

    var task: (String) -> UUID { { sample.taskProperties[$0]! } }
    var project: (String) -> UUID { { sample.projectProperties[$0]! } }

    func rows(of databaseId: UUID) throws -> [UUID] {
        try store.database.dbWriter.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM page WHERE parentId = ? AND trashedAt IS NULL ORDER BY sortKey", arguments: [databaseId.databaseText])
                .compactMap(UUID.init(uuidString:))
        }
    }

    func computed(_ row: UUID, _ property: UUID) throws -> JSONValue? {
        try store.database.dbWriter.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM db_computed WHERE rowId = ? AND propertyId = ?",
                                arguments: [row.databaseText, property.databaseText]).flatMap(FastJSON.parse)
        }
    }

    func hasComputed(_ row: UUID, _ property: UUID) throws -> Bool {
        try store.database.dbWriter.read { db in
            try Bool.fetchOne(db, sql: "SELECT 1 FROM db_computed WHERE rowId = ? AND propertyId = ?", arguments: [row.databaseText, property.databaseText]) ?? false
        }
    }

    func projectNames(of row: UUID) throws -> JSONValue {
        try store.write { tx throws in
            .array(try tx.relationLinks(propertyId: task("Проект"), rowId: row).compactMap { try tx.page($0.targetRowId) }
                .filter { $0.trashedAt == nil }.map { .string($0.title) })
        }
    }

    /// Новое свойство-формула (текст с названиями свойств, как в редакторе).
    @discardableResult
    func addFormula(_ name: String, to databaseId: UUID, _ display: String) throws -> UUID {
        let schema = try DatabaseFormulaSchema.read(databaseId, in: store)
        let stored = try FormulaSource.stored(display, schema: schema)
        return try store.write { tx throws in
            let last = try tx.properties(ofDatabase: databaseId, includingDeleted: true).map(\.sortKey).max()
            return try tx.saveProperty(DatabaseProperty(databaseId: databaseId, name: name, kind: .formula, config: ["expression": .string(stored)],
                                                        sortKey: .between(last, nil))).id
        }
    }

    @Test("Правка флажка пересчитывает «Итог» строки в той же транзакции")
    func editRecomputesInSameTransaction() throws {
        let row = try rows(of: sample.tasksId)[3]
        let old = try store.write { tx in try tx.cell(rowId: row, propertyId: task("Сделано"))?.value?.bool ?? false }
        try store.write { tx throws in _ = try tx.setCell(rowId: row, propertyId: task("Сделано"), value: .bool(!old)) }
        #expect(try computed(row, task("Итог")) == .string(!old ? "Готово" : "В работе"))
        try store.write { tx throws in _ = try tx.setCell(rowId: row, propertyId: task("Сделано"), value: .bool(old)) }
        #expect(try computed(row, task("Итог")) == .string(old ? "Готово" : "В работе"))
    }

    @Test("Формула от формулы той же строки — сразу, в порядке зависимостей")
    func formulaChain() throws {
        let label = try addFormula("Метка", to: sample.tasksId, #"prop("Итог") + "!""#)
        queue.waitUntilIdle()
        let row = try rows(of: sample.tasksId)[5]
        try store.write { tx throws in _ = try tx.setCell(rowId: row, propertyId: task("Сделано"), value: .bool(true)) }
        #expect(try computed(row, label) == .string("Готово!"))
        try store.write { tx throws in _ = try tx.setCell(rowId: row, propertyId: task("Сделано"), value: .bool(false)) }
        #expect(try computed(row, label) == .string("В работе!"))
    }

    @Test("Название проекта поменялось — «Проект (имя)» связанных задач пересчитаны той же записью")
    func relatedRowEdit() throws {
        let tasks = try rows(of: sample.tasksId)
        let row = tasks[0]
        let projectId = try store.write { tx in try tx.relationLinks(propertyId: task("Проект"), rowId: row).first!.targetRowId }
        let linked = try tasks.filter { candidate in
            try store.write { tx in try tx.relationLinks(propertyId: task("Проект"), rowId: candidate).contains { $0.targetRowId == projectId } }
        }
        try store.write { tx throws in
            var page = try tx.page(projectId)!
            page.title = "Переименованный проект"
            try tx.updatePage(page)
        }
        for task in linked { #expect(try computed(task, self.task("Проект (имя)")) == projectNames(of: task)) }
        #expect(try computed(row, task("Проект (имя)")) == .array([.string("Переименованный проект")]))
    }

    @Test("Связь сменилась — итог задачи пересчитан; проект в корзину и обратно — тоже")
    func relationLinksAndTrash() throws {
        let row = try rows(of: sample.tasksId)[7]
        let projects = try rows(of: sample.projectsId)
        let current = try store.write { tx in try tx.relationLinks(propertyId: task("Проект"), rowId: row).first!.targetRowId }
        let other = projects.first { $0 != current }!
        try store.write { tx throws in
            for var link in try tx.relationLinks(propertyId: task("Проект"), rowId: row) {
                link.isPresent = false
                _ = try tx.saveRelationLink(link)
            }
            _ = try tx.saveRelationLink(RelationLink(propertyId: task("Проект"), rowId: row, targetRowId: other, sortKey: .between(nil, nil)))
        }
        #expect(try computed(row, task("Проект (имя)")) == projectNames(of: row))
        #expect(try projectNames(of: row) != .array([]))
        try store.write { tx throws in
            var page = try tx.page(other)!
            page.trashedAt = Date()
            try tx.updatePage(page)
        }
        #expect(try computed(row, task("Проект (имя)")) == .array([]), "проект в корзине — его нет в формуле")
        try store.write { tx throws in
            var page = try tx.page(other)!
            page.trashedAt = nil
            try tx.updatePage(page)
        }
        #expect(try computed(row, task("Проект (имя)")) == projectNames(of: row))
    }

    @Test("Цепочка через связь: формула проекта → формула задачи — обе той же записью, по порядку")
    func chainThroughRelation() throws {
        let projectDue = try addFormula("Срок текстом", to: sample.projectsId, #"formatDate(prop("Срок"), "DD.MM.YYYY")"#)
        let taskDue = try addFormula("Срок проекта текстом", to: sample.tasksId, #"prop("Проект").map(current.prop("Срок текстом")).join(", ")"#)
        queue.waitUntilIdle()
        let row = try rows(of: sample.tasksId)[9]
        let projectId = try store.write { tx in try tx.relationLinks(propertyId: task("Проект"), rowId: row).first!.targetRowId }
        try store.write { tx throws in _ = try tx.setCell(rowId: projectId, propertyId: project("Срок"), value: ["start": "2027-03-08", "hasTime": false]) }
        #expect(try computed(projectId, projectDue) == .string("08.03.2027"))
        #expect(try computed(row, taskDue) == .string("08.03.2027"), "задача прочитала новый итог проекта")
    }

    @Test("Новая строка получает итоги формул той же записью")
    func newRow() throws {
        let row = try store.write { tx throws in try tx.createPage(title: "Новая задача", parentId: sample.tasksId).id }
        #expect(try computed(row, task("Итог")) == .string("В работе"))
        #expect(try computed(row, task("Проект (имя)")) == .array([]))
        #expect(try hasComputed(row, task("Дней до срока")), "пустой итог тоже записан")
    }

    @Test("Новая формула считается в фоне: сразу после записи — пусто, потом — как подсчёт «в лоб» у каждой строки")
    func newFormulaInBackground() throws {
        let blocked = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        queue.enqueueBarrier { blocked.signal(); release.wait() }
        blocked.wait()
        let hours = try addFormula("Часы × 2", to: sample.tasksId, #"prop("Часы") * 2 + length(prop("Теги"))"#)
        let tasks = try rows(of: sample.tasksId)
        #expect(try tasks.allSatisfy { try !hasComputed($0, hours) }, "до готовности у новой формулы — пусто")
        release.signal()
        queue.waitUntilIdle()
        for row in tasks {
            let (hoursValue, tags) = try store.write { tx throws in
                (try tx.cell(rowId: row, propertyId: task("Часы"))?.value?.number, try tx.cell(rowId: row, propertyId: task("Теги"))?.value?.array?.count ?? 0)
            }
            let expected: JSONValue? = hoursValue.map { .number($0 * 2 + Double(tags)) }
            #expect(try computed(row, hours) == expected, "строка \(row)")
        }
    }

    @Test("Правка формулы: до готовности — прежний итог, после — новый")
    func editFormulaKeepsOldUntilReady() throws {
        let tasks = try rows(of: sample.tasksId)
        let before = try computed(tasks[0], task("Итог"))
        let schema = try DatabaseFormulaSchema.read(sample.tasksId, in: store)
        let stored = try FormulaSource.stored(#"if(prop("Сделано"), "да", "нет")"#, schema: schema)
        let blocked = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        queue.enqueueBarrier { blocked.signal(); release.wait() }
        blocked.wait()
        try store.write { tx throws in
            var property = try tx.property(task("Итог"))!
            property.config["expression"] = .string(stored)
            _ = try tx.saveProperty(property)
        }
        #expect(try computed(tasks[0], task("Итог")) == before, "пока пересчёт не дошёл — прежний итог")
        release.signal()
        queue.waitUntilIdle()
        for row in tasks {
            let done = try store.write { tx in try tx.cell(rowId: row, propertyId: task("Сделано"))?.value?.bool ?? false }
            #expect(try computed(row, task("Итог")) == .string(done ? "да" : "нет"))
        }
    }

    @Test("Полный пересчёт и правки одновременно: итог всех строк сходится с подсчётом «в лоб»")
    func backgroundWithConcurrentEdits() throws {
        let tasks = try rows(of: sample.tasksId)
        try store.database.dbWriter.write { try $0.execute(sql: "DELETE FROM db_computed WHERE propertyId = ?", arguments: [task("Итог").databaseText]) }
        queue.enqueue(sample.tasksId)
        for (step, row) in tasks.enumerated() where step % 4 == 0 {
            try store.write { tx throws in
                let old = try tx.cell(rowId: row, propertyId: task("Сделано"))?.value?.bool ?? false
                _ = try tx.setCell(rowId: row, propertyId: task("Сделано"), value: .bool(!old))
            }
        }
        queue.waitUntilIdle()
        for row in tasks {
            let done = try store.write { tx in try tx.cell(rowId: row, propertyId: task("Сделано"))?.value?.bool ?? false }
            #expect(try computed(row, task("Итог")) == .string(done ? "Готово" : "В работе"))
        }
    }

    @Test("Переименование свойства: формула хранит id — итог тот же, редактор показывает новое название")
    func renameKeepsFormula() throws {
        let row = try rows(of: sample.tasksId)[2]
        let before = try computed(row, task("Итог"))
        try store.write { tx throws in
            var property = try tx.property(task("Сделано"))!
            property.name = "Выполнено"
            _ = try tx.saveProperty(property)
        }
        queue.waitUntilIdle()
        let stored = try store.write { tx in try tx.property(task("Итог"))!.config["expression"]!.string! }
        #expect(stored.contains(task("Сделано").databaseText))
        let schema = try DatabaseFormulaSchema.read(sample.tasksId, in: store)
        #expect(FormulaSource.display(stored, schema: schema) == #"if(prop("Выполнено"), "Готово", "В работе")"#)
        #expect(try computed(row, task("Итог")) == before)
        try store.write { tx throws in _ = try tx.setCell(rowId: row, propertyId: task("Сделано"), value: .bool(true)) }
        #expect(try computed(row, task("Итог")) == .string("Готово"))
    }

    @Test("Удалённое свойство — пустой итог (в фоне); вернули — итог вернулся")
    func deletedProperty() throws {
        let row = try rows(of: sample.tasksId).first { candidate in
            try store.write { tx in try tx.cell(rowId: candidate, propertyId: task("Часы"))?.value?.number != nil }
        }!
        let formula = try addFormula("Часы + 1", to: sample.tasksId, #"prop("Часы") + 1"#)
        queue.waitUntilIdle()
        #expect(try computed(row, formula) != nil)
        try store.write { tx throws in
            var property = try tx.property(task("Часы"))!
            property.deletedAt = Date()
            _ = try tx.saveProperty(property)
        }
        queue.waitUntilIdle()
        #expect(try computed(row, formula) == nil)
        try store.write { tx throws in
            var property = try tx.property(task("Часы"))!
            property.deletedAt = nil
            _ = try tx.saveProperty(property)
        }
        queue.waitUntilIdle()
        #expect(try computed(row, formula) != nil)
    }

    @Test("Переименование варианта выбора пересчитывает формулы с этим свойством")
    func optionRename() throws {
        let formula = try addFormula("Приоритет?", to: sample.tasksId, #"prop("Приоритет")"#)
        queue.waitUntilIdle()
        let optionId = sample.options[task("Приоритет")]!["Приоритет 1"]!
        let row = try rows(of: sample.tasksId).first { candidate in
            try store.write { tx in try tx.cell(rowId: candidate, propertyId: task("Приоритет"))?.value?.string == optionId.databaseText }
        }
        try #require(row != nil)
        try store.write { tx throws in
            var option = try tx.option(optionId)!
            option.name = "Высокий"
            _ = try tx.saveOption(option)
        }
        queue.waitUntilIdle()
        #expect(try computed(row!, formula) == .string("Высокий"))
    }

    @Test("«Живые» формулы: раз в минуту только у открытого вида (подменённые часы)")
    @MainActor
    func liveFormulas() throws {
        let start = Date(timeIntervalSince1970: 1_792_600_000)
        clock.now = start
        let taskMinutes = try addFormula("Минут", to: sample.tasksId, #"dateBetween(now(), parseDate("2026-01-01T00:00Z"), "minutes")"#)
        let projectMinutes = try addFormula("Минут", to: sample.projectsId, #"dateBetween(now(), parseDate("2026-01-01T00:00Z"), "minutes")"#)
        queue.waitUntilIdle()
        let task = try rows(of: sample.tasksId)[0], project = try rows(of: sample.projectsId)[0]
        let base = try #require(computed(task, taskMinutes)?.number)
        #expect(try computed(project, projectMinutes)?.number == base)

        let live = LiveFormulaClock(queue: queue)
        live.viewOpened(sample.tasksId)
        clock.now = start.addingTimeInterval(61)
        live.tick()
        queue.waitUntilIdle()
        #expect(try computed(task, taskMinutes)?.number == base + 1, "открытая база — пересчитана")
        #expect(try computed(project, projectMinutes)?.number == base, "закрытая — нет")

        live.viewClosed(sample.tasksId)
        clock.now = start.addingTimeInterval(121)
        live.tick()
        queue.waitUntilIdle()
        #expect(try computed(task, taskMinutes)?.number == base + 1, "вид закрыт — часы не трогают")
        live.viewOpened(sample.projectsId)
        queue.waitUntilIdle()
        #expect(try computed(project, projectMinutes)?.number == base + 2, "открытие вида — сразу пересчёт")
        #expect(try store.database.dbWriter.read { db in
            try Bool.fetchOne(db, sql: "SELECT isLive FROM db_computed WHERE propertyId = ? LIMIT 1", arguments: [taskMinutes.databaseText]) } == true)
    }

    @Test("Фильтр и сортировка по формуле — как у свойства того же типа: число, текст, флажок, дата")
    func filterAndSortByFormula() throws {
        let number = try addFormula("Часы × 10", to: sample.tasksId, #"prop("Часы") * 10"#)
        let flag = try addFormula("Сделано?", to: sample.tasksId, #"prop("Сделано")"#)
        let due = try addFormula("Срок + 1", to: sample.tasksId, #"dateAdd(prop("Срок"), 1, "days")"#)
        queue.waitUntilIdle()
        let catalog = try DatabaseCatalog.read(sample.tasksId, in: store)
        let tasks = try rows(of: sample.tasksId)
        func cell(_ row: UUID, _ name: String) throws -> JSONValue? { try store.write { tx in try tx.cell(rowId: row, propertyId: task(name))?.value } }
        func query(_ filter: FilterNode?, _ sorts: [SortSpec] = []) throws -> [UUID] {
            try ViewQuery.rows(ViewQuerySpec(databaseId: sample.tasksId, filter: filter, sorts: sorts), catalog: catalog, in: store).rowIds
        }
        // Число: больше 50 и по убыванию.
        let hours = try Dictionary(uniqueKeysWithValues: tasks.map { ($0, try cell($0, "Часы")?.number) })
        let over = try query(.condition(FilterCondition(propertyId: number, op: .greaterThan, value: 50)), [SortSpec(propertyId: number, ascending: false)])
        let expected = tasks.filter { (hours[$0] ?? nil).map { $0 * 10 > 50 } ?? false }
        #expect(Set(over) == Set(expected))
        let values = over.map { hours[$0]!! }
        #expect(values == values.sorted(by: >))
        // Флажок.
        let done = try query(.condition(FilterCondition(propertyId: flag, op: .is, value: true)))
        #expect(try Set(done) == Set(tasks.filter { try cell($0, "Сделано")?.bool ?? false }))
        // Текст: «Итог» содержит «Гот».
        let ready = try query(.condition(FilterCondition(propertyId: task("Итог"), op: .contains, value: "Гот")))
        #expect(Set(ready) == Set(done))
        // Дата: по возрастанию — как «Срок».
        let byDue = try query(nil, [SortSpec(propertyId: due, ascending: true)])
        let starts = try byDue.compactMap { try cell($0, "Срок").flatMap(DateValues.start) }
        #expect(starts == starts.sorted())
    }

    @Test("«Готово» редактора: формула с названиями сохраняется с id и типом итога; ошибка и круг — не сохраняются; ⌘Z")
    @MainActor
    func setFormulaOperation() throws {
        let undo = UndoManager()
        undo.groupsByEvent = false
        let operations = DatabaseOperations(store: store, undoManager: undo)
        undo.beginUndoGrouping()
        let property = try operations.addProperty(to: sample.tasksId, name: "Цена", kind: .formula)
        undo.endUndoGrouping()
        undo.beginUndoGrouping()
        #expect(try operations.setFormula(property.id, display: #"prop("Часы") * 1.2"#) == .number)
        undo.endUndoGrouping()
        let saved = try store.write { tx in try tx.property(property.id)!.config }
        #expect(saved["expression"]?.string == #"prop("\#(task("Часы").databaseText)") * 1.2"#)
        #expect(saved["resultType"]?.string == "number")
        #expect(throws: FormulaError("Нет свойства „Срок2“", at: 5..<12)) { try operations.setFormula(property.id, display: #"prop("Срок2")"#) }
        #expect(throws: FormulaError.self) { try operations.setFormula(property.id, display: "if(true, 1") }
        #expect(throws: FormulaError("Формула ссылается сама на себя: Цена → Цена", at: 5..<11)) {
            try operations.setFormula(property.id, display: #"prop("Цена") + 1"#)
        }
        #expect(try store.write { tx in try tx.property(property.id)!.config["expression"]?.string } == saved["expression"]?.string, "ошибочная не сохранилась")
        undo.undo()
        #expect(try store.write { tx in try tx.property(property.id)!.config["expression"]?.string ?? "" } == "")
    }

    @Test("Первое заполнение: строки без итогов формул досчитываются в фоне")
    func fillMissing() throws {
        let tasks = try rows(of: sample.tasksId)
        try store.database.dbWriter.write { try $0.execute(sql: "DELETE FROM db_computed WHERE propertyId = ?", arguments: [task("Итог").databaseText]) }
        queue.fillMissing()
        queue.waitUntilIdle()
        for row in tasks { #expect(try hasComputed(row, task("Итог"))) }
    }

    @Test("Неизменный итог формулы не теряет уведомление о правке исходной ячейки")
    @MainActor
    func unchangedResultStillAnnouncesEdit() throws {
        let constant = try addFormula("Ноль часов", to: sample.tasksId, #"prop("Часы") * 0"#)
        queue.waitUntilIdle()
        let row = try rows(of: sample.tasksId)[0]
        #expect(try computed(row, constant) == .number(0))
        let before = try store.write { try $0.cell(rowId: row, propertyId: task("Часы"))?.value?.number ?? 0 }
        let observed = Mutex<Set<UUID>>([])
        let key = DatabaseOperations.touchedKey
        let observer = NotificationCenter.default.addObserver(forName: DatabaseOperations.didChange, object: nil, queue: .main) { note in
            if let rows = note.userInfo?[key] as? Set<UUID> { observed.withLock { $0.formUnion(rows) } }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let operations = DatabaseOperations(store: store)
        try operations.setCell(rowId: row, propertyId: task("Часы"), value: .number(before + 1))
        #expect(try computed(row, constant) == .number(0))
        #expect(observed.withLock { $0.contains(row) }, "вид строки получает правку даже при прежнем вычисленном кэше")
    }


    @Test("Чужая корзина и возврат пересчитывают цепочку связи, сохраняя несвязанные живые формулы")
    @MainActor
    func indirectEditSelectsDependentProperties() throws {
        let start = Date(timeIntervalSince1970: 1_792_600_000)
        clock.now = start
        let minutes = try addFormula("Минут сейчас", to: sample.tasksId,
                                     #"dateBetween(now(), parseDate("2026-01-01T00:00Z"), "minutes")"#)
        let count = try addFormula("Имен проектов", to: sample.tasksId, #"prop("Проект (имя)").length()"#)
        queue.waitUntilIdle()
        let row = try rows(of: sample.tasksId)[0]
        let projectId = try store.write { try $0.relationLinks(propertyId: task("Проект"), rowId: row).first!.targetRowId }
        let before = try #require(computed(row, minutes)?.number)
        let deadline = try computed(row, task("Срок проекта"))
        #expect(try computed(row, count) == .number(1))
        clock.now = start.addingTimeInterval(61)
        let operations = DatabaseOperations(store: store)
        try operations.trashRows([projectId])
        #expect(try computed(row, task("Проект (имя)")) == .array([]))
        #expect(try computed(row, count) == .number(0), "formula→formula closure после связи")
        #expect(try computed(row, task("Срок проекта")) == nil)
        #expect(try computed(row, minutes)?.number == before)
        try operations.setRowsTrashed([projectId], false)
        #expect(try computed(row, task("Проект (имя)")) == projectNames(of: row))
        #expect(try computed(row, count) == .number(1))
        #expect(try computed(row, task("Срок проекта")) == deadline)
        #expect(try computed(row, minutes)?.number == before)
        let done = try store.write { try $0.cell(rowId: row, propertyId: task("Сделано"))?.value?.bool ?? false }
        try operations.setCell(rowId: row, propertyId: task("Сделано"), value: .bool(!done))
        #expect(try computed(row, minutes)?.number == before + 1, "direct правка сохранила прежний полный пересчёт")
    }

    @Test("Кэш graph после правки формулы: неявное имя страницы, rollup→formula, корзина и стирание цели")
    @MainActor
    func indirectDependenciesAndSchemaInvalidation() throws {
        let label = try addFormula("Имя связи", to: sample.tasksId, #""старое""#)
        let labelChain = try addFormula("Имя с меткой", to: sample.tasksId, #"prop("Имя связи") + "!""#)
        let dateChain = try addFormula("Дата сводки", to: sample.tasksId, #"formatDate(prop("Срок проекта"), "YYYY-MM-DD")"#)
        queue.waitUntilIdle()
        let row = try rows(of: sample.tasksId)[0]
        let projectId = try store.write { try $0.relationLinks(propertyId: task("Проект"), rowId: row).first!.targetRowId }
        let operations = DatabaseOperations(store: store)
        // Убираем явного читателя Названия: переименование обязано заметить само format(связь).
        try operations.setDeleted(task("Проект (имя)"), true)
        queue.waitUntilIdle()
        let hours = try store.write { try $0.cell(rowId: row, propertyId: task("Часы"))?.value?.number ?? 0 }
        try operations.setCell(rowId: row, propertyId: task("Часы"), value: .number(hours + 1)) // graph закэширован
        _ = try operations.setFormula(label, display: #"format(prop("Проект"))"#)
        queue.waitUntilIdle()
        try store.write { tx in
            var page = try tx.page(projectId)!
            page.title = "Новое имя проекта"
            try tx.updatePage(page)
        }
        #expect(try computed(row, label) == .string("Новое имя проекта"), "имя без current.prop(Название)")
        #expect(try computed(row, labelChain) == .string("Новое имя проекта!"))
        try operations.setCell(rowId: projectId, propertyId: project("Срок"), value: ["start": "2027-03-08", "hasTime": false])
        #expect(try computed(row, dateChain) == .string("2027-03-08"), "rollup→formula closure в той же транзакции")
        try operations.trashRows([projectId])
        #expect(try computed(row, label) == .string(""))
        #expect(try computed(row, labelChain) == .string("!"))
        #expect(try computed(row, task("Срок проекта")) == nil)
        try operations.setRowsTrashed([projectId], false)
        #expect(try computed(row, labelChain) == .string("Новое имя проекта!"))
        #expect(try computed(row, dateChain) == .string("2027-03-08"))
        try operations.trashRows([projectId])
        try PageTreeOperations(store: store).deleteForever(projectId)
        #expect(try computed(row, labelChain) == .string("!"))
        #expect(try computed(row, task("Срок проекта")) == nil)
        #expect(try store.write { try $0.relationLinks(propertyId: task("Проект"), rowId: row).isEmpty })
    }

}

/// Подменённые часы.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date()

    var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
