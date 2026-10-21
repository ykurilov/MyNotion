import Foundation
import Testing
@testable import NotesCore
@testable import Sync

/// Слияние баз (T013, research R7, R10): «позднее побеждает» для каждого поля; разные ячейки одной строки с двух Mac —
/// обе; одновременные варианты и связи — все; одна и та же связь с двух Mac — одна запись; ячейка раньше свойства —
/// хранится и показывается после; снимок переносит всё.
@MainActor
@Suite("Слияние правок v4")
struct ChangeMergerV4Tests {
    let numbering = TestJournalNumbering()
    let a: SyncTestMac
    let b: SyncTestMac

    init() throws {
        a = try SyncTestMac(name: "Mac A", wallMillis: 10_000)
        b = try SyncTestMac(name: "Mac B", wallMillis: 10_000)
    }

    @Test("База целиком приходит на второй Mac")
    func databaseArrives() throws {
        let db = try makeTasksDatabase(on: a)
        try exchange([a, b], numbering: numbering)
        try b.store.write { tx throws in
            #expect(try tx.isDatabase(db.database))
            #expect(try tx.properties(ofDatabase: db.database).map(\.name) == ["Название", "Описание", "Статус", "Связано"])
            #expect(try tx.options(ofProperty: db.select).map(\.name) == ["Готово"])
            #expect(try tx.view(db.view)?.layoutOptions["futureKey"] == "x")
            #expect(try tx.cell(rowId: db.row, propertyId: db.select)?.value == .string(db.option.uuidString.lowercased()))
            #expect(try tx.relationLinks(propertyId: db.relation, rowId: db.row).map(\.targetRowId) == [db.otherRow])
            #expect(try tx.rowOrder(viewId: db.view, rowId: db.otherRow) != nil)
        }
        #expect(try b.cellText(db) == "в банк")
    }

    @Test("Каждое поле: позднее побеждает; разные поля одной записи с двух Mac — оба")
    func laterFieldWins() throws {
        let db = try makeTasksDatabase(on: a)
        try exchange([a, b], numbering: numbering)
        a.wall.set(20_000)
        b.wall.set(30_000)
        try a.store.write { tx throws in
            var property = try #require(try tx.property(db.text))
            property.name = "Имя с A"
            try tx.saveProperty(property)
        }
        try b.store.write { tx throws in
            var property = try #require(try tx.property(db.text))
            property.name = "Имя с B"
            property.config = ["note": "B"]
            try tx.saveProperty(property)
            var view = try #require(try tx.view(db.view))
            view.name = "Вид B"
            try tx.saveView(view)
        }
        try a.store.write { tx throws in
            var view = try #require(try tx.view(db.view))
            view.sorts = [["propertyId": .string(db.text.uuidString.lowercased()), "direction": "ascending"]]
            try tx.saveView(view)
        }
        try exchange([a, b], numbering: numbering)
        for mac in [a, b] {
            let property = try #require(try mac.dbProperty(db.text))
            #expect(property.name == "Имя с B", "позднее побеждает")
            #expect(property.config == ["note": "B"])
            let view = try #require(try mac.store.write { try $0.view(db.view) })
            #expect(view.name == "Вид B" && view.sorts.array?.count == 1, "разные поля вида — оба")
        }
    }

    @Test("Разные ячейки одной строки с двух Mac — обе на месте; одна ячейка — позднее побеждает")
    func cellsMerge() throws {
        let db = try makeTasksDatabase(on: a)
        try exchange([a, b], numbering: numbering)
        a.wall.set(20_000)
        b.wall.set(25_000)
        try a.store.write { tx in try tx.setCell(rowId: db.row, propertyId: db.text, value: ["runs": [], "string": "с A"]) }
        try b.store.write { tx in try tx.setCell(rowId: db.row, propertyId: db.select, value: nil) }
        try exchange([a, b], numbering: numbering)
        for mac in [a, b] {
            #expect(try mac.cellText(db) == "с A")
            #expect(try mac.store.write { try $0.cell(rowId: db.row, propertyId: db.select)?.value } == nil)
        }
        a.wall.set(40_000)
        b.wall.set(35_000)
        try a.store.write { tx in try tx.setCell(rowId: db.row, propertyId: db.text, value: ["runs": [], "string": "позже"]) }
        try b.store.write { tx in try tx.setCell(rowId: db.row, propertyId: db.text, value: ["runs": [], "string": "раньше"]) }
        try exchange([a, b], numbering: numbering)
        #expect(try a.cellText(db) == "позже" && b.cellText(db) == "позже")
    }

    @Test("Одновременные варианты и связи — все на месте; одна связь с двух Mac — одна запись")
    func optionsAndLinksMerge() throws {
        let db = try makeTasksDatabase(on: a)
        try exchange([a, b], numbering: numbering)
        let third = try a.store.write { tx in try tx.createPage(title: "Третья", parentId: db.database).id }
        try exchange([a, b], numbering: numbering)
        try a.store.write { tx throws in
            try tx.saveOption(SelectOption(propertyId: db.select, name: "С A", sortKey: FractionalSortKey(rawValue: "x")!))
            try tx.saveRelationLink(RelationLink(propertyId: db.relation, rowId: db.row, targetRowId: third, sortKey: .between(nil, nil)))
            try tx.saveRelationLink(RelationLink(propertyId: db.relation, rowId: db.otherRow, targetRowId: third, sortKey: .between(nil, nil)))
        }
        try b.store.write { tx throws in
            try tx.saveOption(SelectOption(propertyId: db.select, name: "С B", sortKey: FractionalSortKey(rawValue: "y")!))
            try tx.saveRelationLink(RelationLink(propertyId: db.relation, rowId: db.row, targetRowId: third, sortKey: .between(nil, nil)))
            try tx.saveRelationLink(RelationLink(propertyId: db.relation, rowId: third, targetRowId: db.row, sortKey: .between(nil, nil)))
        }
        try exchange([a, b], numbering: numbering)
        for mac in [a, b] {
            try mac.store.write { tx throws in
                #expect(Set(try tx.options(ofProperty: db.select).map(\.name)) == ["Готово", "С A", "С B"])
                #expect(Set(try tx.relationLinks(propertyId: db.relation, rowId: db.row).map(\.targetRowId)) == [db.otherRow, third])
                #expect(try tx.relationLinks(propertyId: db.relation, rowId: db.otherRow).count == 1)
                #expect(try tx.relationLinks(propertyId: db.relation, rowId: third).count == 1)
                #expect(try tx.fetchTexts(sql: "SELECT count(*) FROM db_relation_link").first == "4", "одна связь с двух Mac — одна запись")
            }
        }
    }

    @Test("Ячейка, пришедшая раньше свойства, хранится и показывается, когда свойство придёт")
    func cellBeforeProperty() throws {
        let db = try makeTasksDatabase(on: a)
        try exchange([a, b], numbering: numbering)
        a.wall.set(20_000)
        let (property, row) = try a.store.write { tx throws in
            let property = try tx.saveProperty(DatabaseProperty(databaseId: db.database, name: "Новое", kind: .text, sortKey: FractionalSortKey(rawValue: "z")!))
            try tx.setCell(rowId: db.row, propertyId: property.id, value: ["runs": [], "string": "рано"])
            return (property.id, db.row)
        }
        let changes = try a.takeOutgoing().flatMap(\.changes)
        let cells = changes.filter { $0.entity == .cell }
        let rest = changes.filter { $0.entity != .cell }
        try b.receive([SyncBatch(deviceId: a.serverDeviceId, deviceName: "Mac A", changes: cells)], numbering: numbering)
        #expect(try b.cellText(db, row: row, property: property) == "рано", "ячейка хранится без свойства")
        #expect(try b.dbProperty(property) == nil)
        try b.receive([SyncBatch(deviceId: a.serverDeviceId, deviceName: "Mac A", changes: rest)], numbering: numbering)
        #expect(try b.dbProperty(property)?.name == "Новое")
        #expect(try b.cellText(db, row: row, property: property) == "рано")
    }

    @Test("Снимок для нового Mac переносит базы целиком")
    func snapshotCarriesDatabases() throws {
        let db = try makeTasksDatabase(on: a)
        let snapshot = try SyncSnapshot.make(seq: 3, from: a.store)
        #expect(snapshot.formatVersion == 4)
        let fresh = try SyncTestMac(name: "Mac C", wallMillis: 50_000)
        _ = try fresh.store.write { tx in try ChangeMerger(localDeviceName: "Mac C").apply(snapshot, in: tx) }
        try fresh.store.write { tx throws in
            #expect(try tx.isDatabase(db.database))
            #expect(try tx.properties(ofDatabase: db.database).count == 4)
            #expect(try tx.options(ofProperty: db.select).count == 1)
            #expect(try tx.views(ofDatabase: db.database).count == 1)
            #expect(try tx.cells(ofRow: db.row).count == 2)
            #expect(try tx.relationLinks(propertyId: db.relation, rowId: db.row).count == 1)
            #expect(try tx.rowOrder(viewId: db.view, rowId: db.otherRow) != nil)
        }
        let property = try #require(try a.dbProperty(db.text))
        #expect(snapshot.knowledge.covers(try #require(property.fieldClocks[.name])), "снимок знает метки баз")
    }
}
