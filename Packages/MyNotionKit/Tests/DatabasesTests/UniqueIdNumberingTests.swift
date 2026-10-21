import Foundation
import Testing
@testable import Databases
@testable import NotesCore

/// Номера ID (T033, research R9): 1, 2, 3 по созданию строк; одно свойство ID на базу; номер не переиспользуется после
/// корзины. Файл не `UniqueIdTests.swift`: так называется тест модели типа в `PropertyTypes/`.
@MainActor
@Suite("ID: выдача номеров")
struct UniqueIdNumberingTests {
    let store: NotesStore
    let operations: DatabaseOperations
    let base: CreatedDatabase

    init() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("uniqueid-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = NotesStore(database: try AppDatabase.open(at: folder.appendingPathComponent("MyNotion.sqlite")), clock: HybridLogicalClock(deviceId: UUID()))
        store.addWriteHook(CellIndexer())
        operations = DatabaseOperations(store: store)
        base = try operations.createDatabase(in: nil, isInline: false, title: "Задачи")
    }

    func number(_ row: UUID, _ property: UUID) throws -> Double? {
        try store.write { try $0.cell(rowId: row, propertyId: property)?.value?.number }
    }

    @Test("Свойство ID нумерует прежние строки по созданию, новые получают следующий номер")
    func numbersByCreation() throws {
        let old = try (0..<2).map { _ in try operations.addRow(to: base.databaseId, in: base.viewId) }
        let id = try operations.addProperty(to: base.databaseId, name: "ID", kind: .uniqueId)
        #expect(try old.map { try number($0, id.id) } == [1, 2])
        let third = try operations.addRow(to: base.databaseId, in: base.viewId, at: .top)
        #expect(try number(third, id.id) == 3, "номер — по созданию, а не по месту в виде")
        let copy = try operations.duplicateRows([old[0]], in: base.viewId)
        #expect(try number(copy[0], id.id) == 4, "у копии свой номер")
    }

    @Test("Второе свойство ID не добавляется — ни новым свойством, ни сменой типа")
    func onePerDatabase() throws {
        _ = try operations.addProperty(to: base.databaseId, name: "ID", kind: .uniqueId)
        #expect(throws: (any Error).self) { try operations.addProperty(to: base.databaseId, name: "ID 2", kind: .uniqueId) }
        let text = try operations.addProperty(to: base.databaseId, name: "Текст", kind: .text)
        #expect(throws: (any Error).self) { try operations.changeType(text.id, to: .uniqueId) }
    }

    @Test("Номер строки из корзины не переиспользуется")
    func noReuseAfterTrash() throws {
        let id = try operations.addProperty(to: base.databaseId, name: "ID", kind: .uniqueId)
        let rows = try (0..<3).map { _ in try operations.addRow(to: base.databaseId, in: base.viewId) }
        try operations.trashRows([rows[2]])
        let next = try operations.addRow(to: base.databaseId, in: base.viewId)
        #expect(try number(next, id.id) == 4)
    }

    @Test("Ячейка ID не правится операцией записи блока")
    func notEditable() throws {
        let id = try operations.addProperty(to: base.databaseId, name: "ID", kind: .uniqueId)
        let row = try operations.addRow(to: base.databaseId, in: base.viewId)
        _ = try operations.writeCells([CellWrite(row: .existing(row), propertyId: id.id, value: .number(99))], appendingRows: 0,
                                      to: base.databaseId, in: base.viewId)
        #expect(try number(row, id.id) == 1)
    }

    @Test("Префикс ID (Notion «Prefix»): настройка свойства, номер показывается «ЗАД-1»; ⌘Z возвращает прежний")
    func prefix() throws {
        let undo = UndoManager()
        undo.groupsByEvent = false
        let id = try operations.addProperty(to: base.databaseId, name: "ID", kind: .uniqueId)
        let row = try operations.addRow(to: base.databaseId, in: base.viewId)
        operations.undoManager = undo
        undo.beginUndoGrouping()
        try operations.setPropertyConfig(id.id, ["prefix": "ЗАД"])
        undo.endUndoGrouping()
        func shown() throws -> String {
            let catalog = try DatabaseCatalog.read(base.databaseId, in: store)
            let property = try #require(catalog.propertiesById[id.id])
            return PropertyTypes.type(for: .uniqueId).displayText(try store.write { try $0.cell(rowId: row, propertyId: id.id)?.value },
                                                                   in: catalog.context(for: property))
        }
        #expect(try shown() == "ЗАД-1")
        undo.undo()
        #expect(try shown() == "1")
    }
}

