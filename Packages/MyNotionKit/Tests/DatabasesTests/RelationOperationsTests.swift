import Foundation
import Testing
@testable import Databases
@testable import NotesCore

/// Связи (T086, spec US4, research R7): связь с другой базой и со своей, лимит «1 страница», ответное свойство (сразу и
/// позже), удаление свойства-пары, правка с любой стороны, новая строка цели из окна связи, корзина базы-цели и
/// стирание строки-цели. Каждая правка — один шаг ⌘Z, ⇧⌘Z повторяет.
@MainActor
@Suite("Связи: операции (US4)")
struct RelationOperationsTests {
    let folder: URL
    let store: NotesStore
    let undo = UndoManager()
    let operations: DatabaseOperations
    /// Подготовка без шагов отмены.
    let quiet: DatabaseOperations
    let tasks: CreatedDatabase
    let projects: CreatedDatabase
    let task1: UUID, task2: UUID, task3: UUID
    let projectA: UUID, projectB: UUID

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("relations-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = NotesStore(database: try AppDatabase.open(at: folder.appendingPathComponent("MyNotion.sqlite")), clock: HybridLogicalClock(deviceId: UUID()))
        store.addWriteHook(CellIndexer())
        store.addWriteHook(ComputationHook(store: store, queue: nil))
        undo.groupsByEvent = false
        operations = DatabaseOperations(store: store, undoManager: undo)
        quiet = DatabaseOperations(store: store)
        tasks = try quiet.createDatabase(in: nil, isInline: false, title: "Задачи")
        projects = try quiet.createDatabase(in: nil, isInline: false, title: "Проекты")
        task1 = try quiet.addRow(to: tasks.databaseId, in: nil, title: "Позвонить")
        task2 = try quiet.addRow(to: tasks.databaseId, in: nil, title: "Купить")
        task3 = try quiet.addRow(to: tasks.databaseId, in: nil, title: "Сдать отчёт")
        projectA = try quiet.addRow(to: projects.databaseId, in: nil, title: "Дом")
        projectB = try quiet.addRow(to: projects.databaseId, in: nil, title: "Работа")
    }

    func step(_ body: () throws -> Void) rethrows {
        undo.beginUndoGrouping()
        try body()
        undo.endUndoGrouping()
    }

    func read<T>(_ body: (NotesTransaction) throws -> T) throws -> T { try store.write { tx throws in try body(tx) } }

    /// Названия строк в ячейке связи, как их видит таблица.
    func related(_ row: UUID, _ property: UUID, in databaseId: UUID) throws -> [String] {
        let catalog = try DatabaseCatalog.read(databaseId, in: store)
        return try RowWindowReader.read([row], catalog: catalog, store: store)[row]?.relations[property]?.map(\.title) ?? []
    }

    func property(_ id: UUID) throws -> DatabaseProperty { try #require(try read { try $0.property(id) }) }
    func names(_ databaseId: UUID) throws -> [String] { try read { try $0.properties(ofDatabase: databaseId).map(\.name) } }

    // MARK: Связь

    @Test("Связь с другой базой: строки связаны, видны в ячейке; снять — «−»; каждая правка — шаг ⌘Z / ⇧⌘Z")
    func linkOtherDatabase() throws {
        let relation = try quiet.addRelation(to: tasks.databaseId, name: "Проект", target: projects.databaseId)
        #expect(relation.kind == .relation)
        #expect(relation.relationTarget == projects.databaseId)
        #expect(relation.relationLimit == RelationLimit.none)
        #expect(try names(projects.databaseId) == ["Название"], "без ответного свойства во второй базе ничего не появилось")

        try step { try operations.linkRow(task1, through: relation.id, to: projectA) }
        try step { try operations.linkRow(task1, through: relation.id, to: projectB) }
        #expect(try related(task1, relation.id, in: tasks.databaseId) == ["Дом", "Работа"])
        try step { try operations.unlinkRow(task1, through: relation.id, from: projectA) }
        #expect(try related(task1, relation.id, in: tasks.databaseId) == ["Работа"])

        undo.undo()
        #expect(try related(task1, relation.id, in: tasks.databaseId) == ["Дом", "Работа"])
        undo.undo()
        #expect(try related(task1, relation.id, in: tasks.databaseId) == ["Дом"])
        undo.redo()
        undo.redo()
        #expect(try related(task1, relation.id, in: tasks.databaseId) == ["Работа"])
        // Повтор той же связи ничего не меняет и шага не ставит.
        try step { try operations.linkRow(task1, through: relation.id, to: projectB) }
        #expect(try related(task1, relation.id, in: tasks.databaseId) == ["Работа"])
    }

    @Test("Связь со своей базой: строки этой же базы, в том числе на себя")
    func linkSameDatabase() throws {
        let relation = try quiet.addRelation(to: tasks.databaseId, name: "Зависит от", target: tasks.databaseId)
        try quiet.linkRow(task1, through: relation.id, to: task2)
        try quiet.linkRow(task1, through: relation.id, to: task3)
        try quiet.linkRow(task2, through: relation.id, to: task2)
        #expect(try related(task1, relation.id, in: tasks.databaseId) == ["Купить", "Сдать отчёт"])
        #expect(try related(task2, relation.id, in: tasks.databaseId) == ["Купить"])
        #expect(try related(task3, relation.id, in: tasks.databaseId).isEmpty, "односторонняя — у цели пусто")
    }

    @Test("Лимит «1 страница»: вторая связь снимает прежнюю той же правкой; ⌘Z возвращает прежнюю")
    func limitOnePage() throws {
        let relation = try quiet.addRelation(to: tasks.databaseId, name: "Проект", target: projects.databaseId, limit: .one)
        try step { try operations.linkRow(task1, through: relation.id, to: projectA) }
        try step { try operations.linkRow(task1, through: relation.id, to: projectB) }
        #expect(try related(task1, relation.id, in: tasks.databaseId) == ["Работа"])
        undo.undo()
        #expect(try related(task1, relation.id, in: tasks.databaseId) == ["Дом"], "один шаг: и снятая, и новая")
        undo.redo()
        #expect(try related(task1, relation.id, in: tasks.databaseId) == ["Работа"])

        // Лимит меняется в настройке; прежние связи остаются, следующая правка его соблюдает.
        try step { try operations.setRelationLimit(relation.id, .none) }
        try quiet.linkRow(task1, through: relation.id, to: projectA)
        #expect(try related(task1, relation.id, in: tasks.databaseId) == ["Работа", "Дом"])
        undo.undo()
        #expect(try property(relation.id).relationLimit == .one)
    }

    // MARK: Ответное свойство

    @Test("Ответное свойство при создании: пара во второй базе, связь видна с обеих сторон, правка с любой стороны")
    func twoWayAtCreation() throws {
        try step { _ = try operations.addRelation(to: tasks.databaseId, name: "Проект", target: projects.databaseId, relatedName: "Задачи") }
        let relation = try #require(try read { try $0.properties(ofDatabase: tasks.databaseId) }.first { $0.kind == .relation })
        let paired = try #require(try read { try $0.properties(ofDatabase: projects.databaseId) }.first { $0.kind == .relation })
        #expect(paired.name == "Задачи")
        #expect(paired.relationTarget == tasks.databaseId)
        #expect(paired.pairedRelation == relation.id && relation.pairedRelation == paired.id)

        try quiet.linkRow(task1, through: relation.id, to: projectA)
        try quiet.linkRow(projectA, through: paired.id, to: task2)
        #expect(try related(projectA, paired.id, in: projects.databaseId) == ["Позвонить", "Купить"])
        #expect(try related(task2, relation.id, in: tasks.databaseId) == ["Дом"], "правка со второй стороны видна на первой")
        try quiet.unlinkRow(projectA, through: paired.id, from: task1)
        #expect(try related(task1, relation.id, in: tasks.databaseId).isEmpty)
        #expect(try read { try $0.fetchTexts(sql: "SELECT count(*) FROM db_relation_link") }.first == "2", "одна запись на связь двух сторон")

        // ⌘Z создания убирает оба свойства одним шагом.
        undo.undo()
        #expect(try names(tasks.databaseId) == ["Название"])
        #expect(try names(projects.databaseId) == ["Название"])
        undo.redo()
        #expect(try names(projects.databaseId) == ["Название", "Задачи"])
    }

    @Test("Лимит ответного свойства «1 страница» снимает прежнюю связь цели")
    func pairedLimit() throws {
        let relation = try quiet.addRelation(to: tasks.databaseId, name: "Подзадачи", target: projects.databaseId, relatedName: "Задача")
        try quiet.setRelationLimit(try #require(relation.pairedRelation), .one)
        try quiet.linkRow(task1, through: relation.id, to: projectA)
        try quiet.linkRow(task2, through: relation.id, to: projectA)
        #expect(try related(projectA, try #require(relation.pairedRelation), in: projects.databaseId) == ["Купить"])
        #expect(try related(task1, relation.id, in: tasks.databaseId).isEmpty)
    }

    @Test("Ответное свойство включено позже — прежние связи на месте; выключено — связи остаются; включено снова — то же свойство")
    func twoWayLater() throws {
        let relation = try quiet.addRelation(to: tasks.databaseId, name: "Проект", target: projects.databaseId)
        try quiet.linkRow(task1, through: relation.id, to: projectA)
        try quiet.linkRow(task2, through: relation.id, to: projectA)

        try step { try operations.setRelatedProperty(of: relation.id, enabled: true, name: "Задачи") }
        let paired = try #require(try property(relation.id).pairedRelation)
        #expect(try related(projectA, paired, in: projects.databaseId) == ["Позвонить", "Купить"])

        try step { try operations.setRelatedProperty(of: relation.id, enabled: false) }
        #expect(try names(projects.databaseId) == ["Название"])
        #expect(try related(task1, relation.id, in: tasks.databaseId) == ["Дом"], "связи на месте")
        try quiet.linkRow(task3, through: relation.id, to: projectA)

        try step { try operations.setRelatedProperty(of: relation.id, enabled: true) }
        #expect(try property(relation.id).pairedRelation == paired, "вернулось то же свойство")
        #expect(try related(projectA, paired, in: projects.databaseId) == ["Позвонить", "Купить", "Сдать отчёт"])

        undo.undo()
        undo.undo()
        #expect(try names(projects.databaseId) == ["Название", "Задачи"], "⌘Z выключения возвращает пару")
        undo.undo()
        #expect(try names(projects.databaseId) == ["Название"])
        #expect(try property(relation.id).relationLimit == .none)
    }

    @Test("Удаление свойства-пары: вторая сторона работает; вернули — связи видны с обеих сторон")
    func deletePairedSide() throws {
        let relation = try quiet.addRelation(to: tasks.databaseId, name: "Проект", target: projects.databaseId, relatedName: "Задачи")
        let paired = try #require(relation.pairedRelation)
        try quiet.linkRow(task1, through: relation.id, to: projectA)

        // Удалили первую сторону (у неё хранятся связи) — вторая читает и правит их как прежде.
        try step { try operations.setDeleted(relation.id, true) }
        try quiet.linkRow(projectB, through: paired, to: task2)
        #expect(try related(projectA, paired, in: projects.databaseId) == ["Позвонить"])
        #expect(try related(projectB, paired, in: projects.databaseId) == ["Купить"])
        undo.undo()
        #expect(try related(task2, relation.id, in: tasks.databaseId) == ["Работа"])

        // Удалили вторую — первая работает, вернули — снова пара.
        try step { try operations.setDeleted(paired, true) }
        try quiet.linkRow(task3, through: relation.id, to: projectB)
        undo.undo()
        #expect(try related(projectB, paired, in: projects.databaseId) == ["Купить", "Сдать отчёт"])
    }

    @Test("Двусторонняя связь со своей базой: обе стороны в одной базе")
    func twoWaySameDatabase() throws {
        let relation = try quiet.addRelation(to: tasks.databaseId, name: "Блокирует", target: tasks.databaseId, relatedName: "Ждёт")
        let paired = try #require(relation.pairedRelation)
        #expect(try names(tasks.databaseId) == ["Название", "Блокирует", "Ждёт"])
        try quiet.linkRow(task1, through: relation.id, to: task2)
        try quiet.linkRow(task3, through: paired, to: task1)
        #expect(try related(task2, paired, in: tasks.databaseId) == ["Позвонить"])
        #expect(try related(task1, relation.id, in: tasks.databaseId) == ["Купить", "Сдать отчёт"])
    }

    // MARK: Окно связи

    @Test("«Найти или создать»: новая строка в базе-цели и связь — один шаг ⌘Z")
    func createLinkedRow() throws {
        let relation = try quiet.addRelation(to: tasks.databaseId, name: "Проект", target: projects.databaseId, limit: .one)
        try quiet.linkRow(task1, through: relation.id, to: projectA)
        var created: UUID?
        try step { created = try operations.createLinkedRow(for: task1, through: relation.id, title: "Отпуск") }
        let row = try #require(created)
        #expect(try read { try $0.page(row)?.parentId } == projects.databaseId)
        #expect(try related(task1, relation.id, in: tasks.databaseId) == ["Отпуск"], "лимит снял прежнюю")
        undo.undo()
        #expect(try related(task1, relation.id, in: tasks.databaseId) == ["Дом"])
        #expect(try read { try $0.page(row)?.trashedAt } != nil, "новая строка — в корзине")
        undo.redo()
        #expect(try related(task1, relation.id, in: tasks.databaseId) == ["Отпуск"])
    }

    @Test("Поиск строк цели: по названию без учёта регистра, без корзины и шаблонов; выбранные — отдельно")
    func candidates() throws {
        let relation = try quiet.addRelation(to: tasks.databaseId, name: "Проект", target: projects.databaseId)
        let trashed = try quiet.addRow(to: projects.databaseId, in: nil, title: "Дача")
        try quiet.trashRows([trashed])
        try quiet.linkRow(task1, through: relation.id, to: projectB)
        let all = try RelationLinks.candidates(for: relation, matching: "", in: store)
        #expect(all.map(\.title) == ["Дом", "Работа"])
        #expect(try RelationLinks.candidates(for: relation, matching: "ра", in: store).map(\.title) == ["Работа"])
        #expect(try RelationLinks.candidates(for: relation, matching: "ДО", in: store).map(\.title) == ["Дом"])
        #expect(try RelationLinks.related(task1, through: relation, in: store).map(\.title) == ["Работа"])
    }

    // MARK: Корзина и стирание

    @Test("Строка-цель в корзине не видна в связи; вернули — снова там")
    func targetRowTrash() throws {
        let relation = try quiet.addRelation(to: tasks.databaseId, name: "Проект", target: projects.databaseId, relatedName: "Задачи")
        try quiet.linkRow(task1, through: relation.id, to: projectA)
        try quiet.linkRow(task1, through: relation.id, to: projectB)
        try quiet.trashRows([projectA])
        #expect(try related(task1, relation.id, in: tasks.databaseId) == ["Работа"])
        try quiet.setRowsTrashed([projectA], false)
        #expect(try related(task1, relation.id, in: tasks.databaseId) == ["Дом", "Работа"])
    }

    @Test("База-цель в корзине: её строки не видны в связях; вернули — связи на месте; стёрли навсегда — свойство пустое, «база удалена»")
    func targetDatabaseTrash() throws {
        let relation = try quiet.addRelation(to: tasks.databaseId, name: "Проект", target: projects.databaseId)
        try quiet.linkRow(task1, through: relation.id, to: projectA)
        let tree = PageTreeOperations(store: store)
        try tree.moveToTrash(projects.databaseId)
        #expect(try related(task1, relation.id, in: tasks.databaseId).isEmpty)
        #expect(try RelationLinks.targetState(of: relation, in: store) == .trashed)
        try tree.restore(projects.databaseId)
        #expect(try related(task1, relation.id, in: tasks.databaseId) == ["Дом"])
        #expect(try RelationLinks.targetState(of: relation, in: store) == .available(title: "Проекты"))

        try tree.moveToTrash(projects.databaseId)
        try tree.deleteForever(projects.databaseId)
        #expect(try related(task1, relation.id, in: tasks.databaseId).isEmpty)
        #expect(try names(tasks.databaseId) == ["Название", "Проект"], "свойство остаётся")
        #expect(try RelationLinks.targetState(of: relation, in: store) == .erased)
        #expect(try read { try $0.fetchTexts(sql: "SELECT count(*) FROM db_relation_link") }.first == "0", "связи со стёртыми строками убраны")
    }
}
