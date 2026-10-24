import Foundation
import Testing
@testable import Databases
@testable import NotesCore

/// База для окон вида: «Задачи» со свойствами нужных типов и тремя строками.
@MainActor
struct PanelTestBase {
    let store: NotesStore
    let operations: DatabaseOperations
    let base: CreatedDatabase
    let text, number, select, multi, status, check, date, formula: DatabaseProperty
    let options: [SelectOption]

    init() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("panels-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = NotesStore(database: try AppDatabase.open(at: folder.appendingPathComponent("MyNotion.sqlite")), clock: HybridLogicalClock(deviceId: UUID()))
        store.addWriteHook(CellIndexer())
        operations = DatabaseOperations(store: store)
        base = try operations.createDatabase(in: nil, isInline: false, title: "Задачи")
        select = try operations.addProperty(to: base.databaseId, name: "Приоритет", kind: .select)
        let selectId = self.select.id
        options = try store.write { tx throws in
            var key: FractionalSortKey?
            return try ["Высокий", "Средний", "Низкий"].map { name -> SelectOption in
                key = .between(key, nil)
                return try tx.saveOption(SelectOption(propertyId: selectId, name: name, color: .red, sortKey: key!))
            }
        }
        multi = try operations.addProperty(to: base.databaseId, name: "Теги", kind: .multiSelect)
        status = try operations.addProperty(to: base.databaseId, name: "Статус", kind: .status)
        text = try operations.addProperty(to: base.databaseId, name: "Описание", kind: .text)
        number = try operations.addProperty(to: base.databaseId, name: "Часы", kind: .number)
        check = try operations.addProperty(to: base.databaseId, name: "Сделано", kind: .checkbox)
        date = try operations.addProperty(to: base.databaseId, name: "Срок", kind: .date)
        formula = try operations.addProperty(to: base.databaseId, name: "Итог", kind: .formula, config: ["expression": "1", "resultType": "number"])
        for (title, hours) in [("Отчёт", 3.0), ("Звонок", 1.0), ("Бюджет", 5.0)] {
            let row = try operations.addRow(to: base.databaseId, in: nil, title: title)
            try operations.setCell(rowId: row, propertyId: number.id, value: .number(hours))
        }
    }

    func view() throws -> DatabaseView { try #require(try store.write { try $0.view(base.viewId) }) }
    func catalog() throws -> DatabaseCatalog { try DatabaseCatalog.read(base.databaseId, in: store) }
    func property(_ name: String) throws -> DatabaseProperty { try #require(try catalog().properties.first { $0.name == name }) }
    func groups() throws -> [ViewGroup]? { try ViewQuery.present(base.viewId, in: store)?.groups }
}
