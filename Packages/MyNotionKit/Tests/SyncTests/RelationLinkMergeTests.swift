import Foundation
import Testing
@testable import Databases
@testable import NotesCore
@testable import Sync

/// Связи на двух Mac (T087, research R7): каждая связь — своя запись, поэтому связи, добавленные одновременно, не
/// теряются; снятие и добавление одной связи — «позднее побеждает»; связь без пришедшей строки-цели хранится и
/// показывается, когда строка придёт; сводки после встречи одинаковые — каждый Mac считает их сам.
@MainActor
@Suite("Связи на двух Mac")
struct RelationLinkMergeTests {
    let numbering = TestJournalNumbering()
    let a: SyncTestMac
    let b: SyncTestMac

    init() throws {
        a = try SyncTestMac(name: "Mac A", wallMillis: 10_000)
        b = try SyncTestMac(name: "Mac B", wallMillis: 10_000)
        for mac in [a, b] { mac.store.addWriteHook(ComputationHook(store: mac.store, queue: nil)) }
    }

    /// «Задачи» ↔ «Проекты» (двусторонняя связь) и сводка «Часов» у проекта, на обоих Mac.
    struct Bases {
        var tasks: UUID, projects: UUID, hours: UUID, relation: UUID, paired: UUID, sum: UUID
        var task1: UUID, task2: UUID, project: UUID
    }

    func makeBases() throws -> Bases {
        let operations = DatabaseOperations(store: a.store)
        let tasks = try operations.createDatabase(in: nil, isInline: false, title: "Задачи").databaseId
        let projects = try operations.createDatabase(in: nil, isInline: false, title: "Проекты").databaseId
        let hours = try operations.addProperty(to: tasks, name: "Часы", kind: .number).id
        let relation = try operations.addRelation(to: tasks, name: "Проект", target: projects, relatedName: "Задачи")
        let paired = try #require(relation.pairedRelation)
        let sum = try operations.addProperty(to: projects, name: "Часов", kind: .rollup,
                                             config: ["relationPropertyId": .string(paired.databaseText), "targetPropertyId": .string(hours.databaseText),
                                                      "calculation": "sum"]).id
        let task1 = try operations.addRow(to: tasks, in: nil, title: "Позвонить")
        let task2 = try operations.addRow(to: tasks, in: nil, title: "Купить")
        let project = try operations.addRow(to: projects, in: nil, title: "Дом")
        try operations.setCell(rowId: task1, propertyId: hours, value: 2)
        try operations.setCell(rowId: task2, propertyId: hours, value: 3)
        try exchange([a, b], numbering: numbering)
        return Bases(tasks: tasks, projects: projects, hours: hours, relation: relation.id, paired: paired, sum: sum,
                     task1: task1, task2: task2, project: project)
    }

    func related(on mac: SyncTestMac, _ row: UUID, _ property: UUID, in databaseId: UUID) throws -> [String] {
        let catalog = try DatabaseCatalog.read(databaseId, in: mac.store)
        return try RowWindowReader.read([row], catalog: catalog, store: mac.store)[row]?.relations[property]?.map(\.title) ?? []
    }

    func sum(on mac: SyncTestMac, _ bases: Bases) throws -> JSONValue? {
        try mac.store.database.dbWriter.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM db_computed WHERE rowId = ? AND propertyId = ?",
                                arguments: [bases.project.databaseText, bases.sum.databaseText]).flatMap(FastJSON.parse)
        }
    }

    @Test("Связи с двух Mac к одной строке — обе на месте, с обеих сторон; сводка одинаковая")
    func concurrentLinks() throws {
        let bases = try makeBases()
        try DatabaseOperations(store: a.store).linkRow(bases.task1, through: bases.relation, to: bases.project)
        try DatabaseOperations(store: b.store).linkRow(bases.project, through: bases.paired, to: bases.task2)
        try exchange([a, b], numbering: numbering)
        for mac in [a, b] {
            #expect(Set(try related(on: mac, bases.project, bases.paired, in: bases.projects)) == ["Позвонить", "Купить"], "\(mac.name)")
            #expect(try related(on: mac, bases.task2, bases.relation, in: bases.tasks) == ["Дом"])
            #expect(try sum(on: mac, bases) == 5, "сводка пересчитана правками с другого Mac")
        }
    }

    @Test("Снятие и добавление одной связи одновременно — позднее побеждает (в обе стороны)")
    func removeVersusAdd() throws {
        let bases = try makeBases()
        try DatabaseOperations(store: a.store).linkRow(bases.task1, through: bases.relation, to: bases.project)
        try exchange([a, b], numbering: numbering)

        // A снимает раньше, B снимает и снова добавляет позже — связь есть.
        a.wall.set(20_000)
        b.wall.set(30_000)
        try DatabaseOperations(store: a.store).unlinkRow(bases.task1, through: bases.relation, from: bases.project)
        try DatabaseOperations(store: b.store).unlinkRow(bases.project, through: bases.paired, from: bases.task1)
        try DatabaseOperations(store: b.store).linkRow(bases.project, through: bases.paired, to: bases.task1)
        try exchange([a, b], numbering: numbering)
        for mac in [a, b] {
            #expect(try related(on: mac, bases.task1, bases.relation, in: bases.tasks) == ["Дом"], "\(mac.name): позднее добавление")
            #expect(try sum(on: mac, bases) == 2)
        }

        // A снимает позже, чем B переставляет (меняет место) — связи нет.
        a.wall.set(50_000)
        b.wall.set(40_000)
        try DatabaseOperations(store: b.store).linkRow(bases.task2, through: bases.relation, to: bases.project)
        try DatabaseOperations(store: a.store).unlinkRow(bases.task1, through: bases.relation, from: bases.project)
        try exchange([a, b], numbering: numbering)
        for mac in [a, b] {
            #expect(try related(on: mac, bases.project, bases.paired, in: bases.projects) == ["Купить"], "\(mac.name): позднее снятие")
            #expect(try sum(on: mac, bases) == 3)
        }
    }

    @Test("Связь, пришедшая раньше строки-цели, хранится и показывается, когда строка придёт")
    func linkBeforeTarget() throws {
        let bases = try makeBases()
        let operations = DatabaseOperations(store: a.store)
        let newProject = try operations.addRow(to: bases.projects, in: nil, title: "Дача")
        try operations.linkRow(bases.task1, through: bases.relation, to: newProject)
        let changes = try a.takeOutgoing().flatMap(\.changes)
        let links = changes.filter { $0.entity == .relationLink }
        let rest = changes.filter { $0.entity != .relationLink }
        try b.receive([SyncBatch(deviceId: a.serverDeviceId, deviceName: "Mac A", changes: links)], numbering: numbering)
        #expect(try b.store.write { tx in try tx.relationLinks(propertyId: bases.relation, rowId: bases.task1).count } == 1, "связь хранится")
        #expect(try related(on: b, bases.task1, bases.relation, in: bases.tasks).isEmpty, "строки ещё нет — не показывается")
        try b.receive([SyncBatch(deviceId: a.serverDeviceId, deviceName: "Mac A", changes: rest)], numbering: numbering)
        #expect(try related(on: b, bases.task1, bases.relation, in: bases.tasks) == ["Дача"])
    }

    @Test("Строка-цель в корзине на одном Mac, новая связь к ней на другом — связь хранится; возврат показывает её")
    func trashVersusLink() throws {
        let bases = try makeBases()
        try DatabaseOperations(store: a.store).trashRows([bases.project])
        try DatabaseOperations(store: b.store).linkRow(bases.task2, through: bases.relation, to: bases.project)
        try exchange([a, b], numbering: numbering)
        for mac in [a, b] {
            #expect(try related(on: mac, bases.task2, bases.relation, in: bases.tasks).isEmpty, "\(mac.name): цель в корзине")
        }
        try DatabaseOperations(store: a.store).setRowsTrashed([bases.project], false)
        try exchange([a, b], numbering: numbering)
        for mac in [a, b] {
            #expect(try related(on: mac, bases.task2, bases.relation, in: bases.tasks) == ["Дом"], "\(mac.name): связь вернулась")
            #expect(try sum(on: mac, bases) == 3)
        }
    }

    @Test("Ответное свойство, включённое на одном Mac, и связи с другого — сходятся")
    func pairEnabledVersusLinks() throws {
        let operations = DatabaseOperations(store: a.store)
        let tasks = try operations.createDatabase(in: nil, isInline: false, title: "Задачи").databaseId
        let projects = try operations.createDatabase(in: nil, isInline: false, title: "Проекты").databaseId
        let relation = try operations.addRelation(to: tasks, name: "Проект", target: projects)
        let task = try operations.addRow(to: tasks, in: nil, title: "Позвонить")
        let project = try operations.addRow(to: projects, in: nil, title: "Дом")
        try exchange([a, b], numbering: numbering)
        try operations.setRelatedProperty(of: relation.id, enabled: true, name: "Задачи")
        try DatabaseOperations(store: b.store).linkRow(task, through: relation.id, to: project)
        try exchange([a, b], numbering: numbering)
        let paired = try #require(try a.dbProperty(relation.id)?.pairedRelation)
        for mac in [a, b] {
            #expect(try related(on: mac, project, paired, in: projects) == ["Позвонить"], "\(mac.name)")
        }
    }
}
