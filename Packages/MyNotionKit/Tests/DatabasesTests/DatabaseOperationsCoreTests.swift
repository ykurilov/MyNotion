import Foundation
import Testing
@testable import Databases
@testable import NotesCore

/// Операции-основа (T025, research R11): создать базу (полностраничную и встроенную), добавить свойство, записать
/// ячейку — одна правка, одна транзакция, один шаг ⌘Z; ⇧⌘Z повторяет.
@MainActor
@Suite("Операции баз: основа")
struct DatabaseOperationsCoreTests {
    let folder: URL
    let store: NotesStore
    let undo = UndoManager()
    let operations: DatabaseOperations
    let host: UUID
    let anchor: UUID

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("dbops-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = NotesStore(database: try AppDatabase.open(at: folder.appendingPathComponent("MyNotion.sqlite")), clock: HybridLogicalClock(deviceId: UUID()))
        undo.groupsByEvent = false
        operations = DatabaseOperations(store: store, undoManager: undo)
        (host, anchor) = try store.write { tx throws in
            let page = try tx.createPage(title: "Хозяин")
            return (page.id, try tx.blocks(ofPage: page.id)[0].id)
        }
    }

    func step(_ body: () throws -> Void) rethrows {
        undo.beginUndoGrouping()
        try body()
        undo.endUndoGrouping()
    }

    @Test("Полностраничная: подстраница-база со ссылкой, свойство «Название», вид «Таблица»; ⌘Z — в корзину, ⇧⌘Z — обратно")
    func fullPage() throws {
        var created: CreatedDatabase!
        try step { created = try operations.createDatabase(in: host, isInline: false, linkAt: .after(blockId: anchor)) }
        try store.write { tx throws in
            let page = try #require(try tx.page(created.databaseId))
            #expect(page.parentId == host && page.title.isEmpty)
            #expect(try tx.database(created.databaseId)?.isInline == false)
            #expect(try tx.properties(ofDatabase: created.databaseId).map(\.name) == ["Название"])
            #expect(try tx.properties(ofDatabase: created.databaseId).first?.kind == .title)
            let view = try #require(try tx.views(ofDatabase: created.databaseId).first)
            #expect(view.name == "Таблица" && view.type == "table" && view.id == created.viewId)
            let blocks = try tx.blocks(ofPage: host)
            #expect(blocks.map(\.kind) == [.paragraph, .pageLink] && blocks[1].linkedPageId == created.databaseId)
        }
        undo.undo()
        try store.write { tx throws in
            #expect(try tx.page(created.databaseId)?.trashedAt != nil)
            #expect(try tx.blocks(ofPage: host).map(\.kind) == [.paragraph])
        }
        undo.redo()
        try store.write { tx throws in
            #expect(try tx.page(created.databaseId)?.trashedAt == nil)
            #expect(try tx.blocks(ofPage: host).map(\.kind) == [.paragraph, .pageLink])
        }
    }

    @Test("Встроенная: блок `database` на месте пустого абзаца, страница-база дочерняя, `isInline`")
    func inline() throws {
        var created: CreatedDatabase!
        try step { created = try operations.createDatabase(in: host, isInline: true, linkAt: .replacing(blockId: anchor)) }
        try store.write { tx throws in
            #expect(try tx.database(created.databaseId)?.isInline == true)
            let blocks = try tx.blocks(ofPage: host)
            #expect(blocks.map(\.kind) == [.database] && blocks[0].linkedPageId == created.databaseId)
        }
        undo.undo()
        try store.write { tx throws in
            #expect(try tx.blocks(ofPage: host).map(\.kind) == [.paragraph], "на месте базы — снова абзац")
            #expect(try tx.page(created.databaseId)?.trashedAt != nil)
        }
    }

    @Test("Добавить свойство — в конец, ⌘Z — в «Удалённые свойства», ⇧⌘Z — обратно; ячейка — ⌘Z возвращает прежнее")
    func propertyAndCell() throws {
        var created: CreatedDatabase!
        try step { created = try operations.createDatabase(in: host, isInline: false, linkAt: .after(blockId: anchor)) }
        var property: DatabaseProperty!
        try step { property = try operations.addProperty(to: created.databaseId, name: "Статус", kind: .select) }
        #expect(try store.write { try $0.properties(ofDatabase: created.databaseId).map(\.name) } == ["Название", "Статус"])
        undo.undo()
        #expect(try store.write { try $0.property(property.id)?.deletedAt } != nil)
        undo.redo()
        #expect(try store.write { try $0.property(property.id)?.deletedAt } == nil)

        var text: DatabaseProperty!
        try step { text = try operations.addProperty(to: created.databaseId, name: "Текст", kind: .text) }
        let row = try store.write { tx in try tx.createPage(title: "Строка", parentId: created.databaseId).id }
        try step { try operations.setCell(rowId: row, propertyId: text.id, value: ["runs": [], "string": "раз"]) }
        try step { try operations.setCell(rowId: row, propertyId: text.id, value: ["runs": [], "string": "два"]) }
        func value() throws -> String? { try store.write { try $0.cell(rowId: row, propertyId: text.id)?.value?["string"]?.string } }
        #expect(try value() == "два")
        undo.undo()
        #expect(try value() == "раз")
        undo.undo()
        #expect(try value() == nil)
        undo.redo()
        #expect(try value() == "раз")
    }
}
