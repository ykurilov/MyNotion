import Foundation
import Synchronization
import Testing
@testable import NotesCore

/// Записи баз в транзакции ядра (T011, data-model.md): запись и чтение, метки полей, неизвестные ключи JSON,
/// «изменено» строки, `NotesChanges.database`, корзина и стирание.
@Suite("Записи баз")
struct DatabaseRecordsTests {
    let wall = AdjustableWallClock(millis: 1_000)
    let device = UUID()

    func makeStore(_ folder: TemporaryFolder) throws -> NotesStore {
        try NotesStore(database: AppDatabase.open(at: folder.databaseURL), clock: HybridLogicalClock(deviceId: device, wallClock: wall.reading))
    }

    /// База «Задачи» со свойством-текстом, выбором и одной строкой.
    func makeDatabase(_ store: NotesStore) throws -> (database: UUID, text: DatabaseProperty, select: DatabaseProperty, row: UUID) {
        try store.write { tx throws in
            let page = try tx.createPage(title: "Задачи")
            try tx.saveDatabase(DatabaseSchema(pageId: page.id))
            let title = try tx.saveProperty(DatabaseProperty(databaseId: page.id, name: "Название", kind: .title, sortKey: .between(nil, nil)))
            let text = try tx.saveProperty(DatabaseProperty(databaseId: page.id, name: "Описание", kind: .text, sortKey: .between(title.sortKey, nil)))
            let select = try tx.saveProperty(DatabaseProperty(databaseId: page.id, name: "Статус", kind: .select, sortKey: .between(text.sortKey, nil)))
            let row = try tx.createPage(title: "Позвонить", parentId: page.id)
            return (page.id, text, select, row.id)
        }
    }

    @Test("База, свойство, вариант, вид, ячейка, связь, место строки — записываются и читаются; у полей — метки")
    func writesAndReadsAllRecords() throws {
        let folder = try TemporaryFolder()
        let store = try makeStore(folder)
        let (database, text, select, row) = try makeDatabase(store)
        wall.set(2_000)
        let (option, view, link, order) = try store.write { tx throws in
            let option = try tx.saveOption(SelectOption(propertyId: select.id, name: "В работе", color: .blue, sortKey: .between(nil, nil),
                                                        statusGroup: .inProgress))
            let view = try tx.saveView(DatabaseView(databaseId: database, sortKey: .between(nil, nil), sorts: [["propertyId": .string(text.id.databaseText), "direction": "ascending"]]))
            try tx.setCell(rowId: row, propertyId: text.id, value: ["runs": [], "string": "Банк"])
            try tx.setCell(rowId: row, propertyId: select.id, value: .string(option.id.databaseText))
            let target = try tx.createPage(title: "Цель", parentId: database)
            let link = try tx.saveRelationLink(RelationLink(propertyId: text.id, rowId: row, targetRowId: target.id, sortKey: .between(nil, nil)))
            let order = try tx.setRowOrder(viewId: view.id, rowId: row, sortKey: .between(nil, nil))
            return (option, view, link, order)
        }
        try store.write { tx throws in
            #expect(try tx.database(database)?.isInline == false)
            #expect(try tx.isDatabase(database))
            #expect(try tx.properties(ofDatabase: database).map(\.name) == ["Название", "Описание", "Статус"])
            #expect(try tx.options(ofProperty: select.id) == [option])
            #expect(try tx.views(ofDatabase: database) == [view])
            #expect(try tx.cell(rowId: row, propertyId: text.id)?.value?["string"] == .string("Банк"))
            #expect(try tx.cells(ofRow: row).count == 2)
            #expect(try tx.relationLink(link.id) == link)
            #expect(try tx.rowOrder(viewId: view.id, rowId: row) == order)
            let stored = try #require(try tx.property(text.id))
            #expect(stored.fieldClocks[.name]?.wallMillis == 1_000 && stored.fieldClocks[.typeAndConfig] != nil)
            #expect(option.fieldClocks[.placement]?.wallMillis == 2_000)
        }
        // Переименование — новая метка только у имени.
        wall.set(3_000)
        try store.write { tx throws in
            var renamed = try #require(try tx.property(text.id))
            renamed.name = "Подробности"
            try tx.saveProperty(renamed)
        }
        try store.write { tx throws in
            let stored = try #require(try tx.property(text.id))
            #expect(stored.fieldClocks[.name]?.wallMillis == 3_000)
            #expect(stored.fieldClocks[.typeAndConfig]?.wallMillis == 1_000)
        }
    }

    @Test("Неизвестные ключи `config` и `layoutOptions` сохраняются как есть")
    func keepsUnknownKeys() throws {
        let folder = try TemporaryFolder()
        let store = try makeStore(folder)
        let (database, _, _, _) = try makeDatabase(store)
        let config: JSONValue = ["format": "percent", "futureKey": ["nested": [1, 2, true]]]
        let layout: JSONValue = ["loadLimit": 25, "cardSize": "large", "boardColumns": ["x"]]
        let (propertyId, viewId) = try store.write { tx throws in
            (try tx.saveProperty(DatabaseProperty(databaseId: database, name: "Число", kind: .number, config: config, sortKey: .between(nil, nil))).id,
             try tx.saveView(DatabaseView(databaseId: database, type: "board", sortKey: .between(nil, nil), layoutOptions: layout)).id)
        }
        try store.write { tx throws in
            #expect(try tx.property(propertyId)?.config == config)
            #expect(try tx.view(viewId)?.layoutOptions == layout)
            #expect(try tx.view(viewId)?.type == "board")
        }
    }

    @Test("Правка ячейки меняет «изменено» строки; пустое значение остаётся записью с меткой")
    func cellEditTouchesRow() throws {
        let folder = try TemporaryFolder()
        let store = try makeStore(folder)
        let (_, text, _, row) = try makeDatabase(store)
        let before = try #require(try store.pageContent(row)?.page.updatedAt)
        Thread.sleep(forTimeInterval: 0.01)
        try store.write { tx in try tx.setCell(rowId: row, propertyId: text.id, value: ["runs": [], "string": "x"]) }
        let after = try #require(try store.pageContent(row)?.page.updatedAt)
        #expect(after > before)
        try store.write { tx in try tx.setCell(rowId: row, propertyId: text.id, value: nil) }
        try store.write { tx throws in
            let cell = try #require(try tx.cell(rowId: row, propertyId: text.id))
            #expect(cell.value == nil)
        }
    }

    @Test("`NotesChanges.database` несёт все новые записи транзакции")
    func changesCarryRecords() throws {
        let folder = try TemporaryFolder()
        let store = try makeStore(folder)
        let recorder = ChangesRecorder()
        store.addWriteHook(recorder)
        let (database, text, select, row) = try makeDatabase(store)
        try store.write { tx throws in
            try tx.saveOption(SelectOption(propertyId: select.id, name: "Готово", sortKey: .between(nil, nil)))
            let view = try tx.saveView(DatabaseView(databaseId: database, sortKey: .between(nil, nil)))
            try tx.setCell(rowId: row, propertyId: text.id, value: ["runs": [], "string": "a"])
            try tx.saveRelationLink(RelationLink(propertyId: text.id, rowId: row, targetRowId: row, sortKey: .between(nil, nil)))
            try tx.setRowOrder(viewId: view.id, rowId: row, sortKey: .between(nil, nil))
        }
        let all = recorder.all
        #expect(all.flatMap(\.database.databases).map(\.record.pageId) == [database])
        #expect(all.flatMap(\.database.properties).count == 3)
        #expect(all.flatMap(\.database.options).first?.isNew == true)
        #expect(all.flatMap(\.database.views).count == 1)
        #expect(all.flatMap(\.database.cells).map(\.propertyId) == [text.id])
        #expect(all.flatMap(\.database.relationLinks).count == 1)
        #expect(all.flatMap(\.database.rowOrders).count == 1)
        #expect(all.last?.isEmpty == false)
    }

    @MainActor
    @Test("Строка в корзине ячейки не теряет; стирание строки стирает её ячейки, связи и места; стирание базы — схему")
    func trashKeepsErasureRemoves() throws {
        let folder = try TemporaryFolder()
        let store = try makeStore(folder)
        let (database, text, _, row) = try makeDatabase(store)
        let other = try store.write { tx in try tx.createPage(title: "Другая", parentId: database).id }
        let view = try store.write { tx throws in
            try tx.setCell(rowId: row, propertyId: text.id, value: ["runs": [], "string": "живое"])
            try tx.saveRelationLink(RelationLink(propertyId: text.id, rowId: other, targetRowId: row, sortKey: .between(nil, nil)))
            let view = try tx.saveView(DatabaseView(databaseId: database, sortKey: .between(nil, nil)))
            try tx.setRowOrder(viewId: view.id, rowId: row, sortKey: .between(nil, nil))
            return view
        }
        let operations = PageTreeOperations(store: store)
        try operations.moveToTrash(row)
        try store.write { tx throws in #expect(try tx.cell(rowId: row, propertyId: text.id)?.value != nil) }
        try operations.deleteForever(row)
        try store.write { tx throws in
            #expect(try tx.cells(ofRow: row).isEmpty)
            #expect(try tx.relationLinks(propertyId: text.id, rowId: other, includingRemoved: true).isEmpty)
            #expect(try tx.rowOrder(viewId: view.id, rowId: row) == nil)
        }
        try operations.moveToTrash(database)
        try operations.deleteForever(database)
        try store.write { tx throws in
            #expect(try tx.database(database) == nil)
            #expect(try tx.properties(ofDatabase: database, includingDeleted: true).isEmpty)
            #expect(try tx.views(ofDatabase: database).isEmpty)
        }
    }
}

/// Подписчик-записыватель: что пришло в каждой транзакции.
final class ChangesRecorder: NotesWriteHook {
    private let changes = Mutex<[NotesChanges]>([])
    var all: [NotesChanges] { changes.withLock { $0 } }

    func notesWillCommit(_ changes: NotesChanges, in transaction: NotesTransaction) throws {
        self.changes.withLock { $0.append(changes) }
    }
}
