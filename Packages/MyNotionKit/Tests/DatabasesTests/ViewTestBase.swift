import Foundation
import Testing
@testable import Databases
@testable import NotesCore

/// База для проверок вида (US3): «Задачи» со свойствами всех нужных типов и шестью строками.
@MainActor
struct ViewTestBase {
    let folder: URL
    let store: NotesStore
    let undo = UndoManager()
    let operations: DatabaseOperations
    /// Подготовка без шагов отмены.
    let quiet: DatabaseOperations
    let base: CreatedDatabase
    let text, number, select, multi, check, date: DatabaseProperty
    let options: [SelectOption]
    let tags: [SelectOption]
    var rows: [UUID] = []

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("view-us3-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = NotesStore(database: try AppDatabase.open(at: folder.appendingPathComponent("MyNotion.sqlite")), clock: HybridLogicalClock(deviceId: UUID()))
        store.addWriteHook(CellIndexer())
        undo.groupsByEvent = false
        operations = DatabaseOperations(store: store, undoManager: undo)
        quiet = DatabaseOperations(store: store)
        let base = try quiet.createDatabase(in: nil, isInline: false, title: "Задачи")
        let select = try quiet.addProperty(to: base.databaseId, name: "Приоритет", kind: .select)
        let multi = try quiet.addProperty(to: base.databaseId, name: "Теги", kind: .multiSelect)
        let made = try store.write { tx throws in
            var key: FractionalSortKey?
            let options = try ["Высокий", "Средний", "Низкий"].map { name -> SelectOption in
                key = .between(key, nil)
                return try tx.saveOption(SelectOption(propertyId: select.id, name: name, color: .red, sortKey: key!))
            }
            key = nil
            let tags = try ["Срочно", "Дом"].map { name -> SelectOption in
                key = .between(key, nil)
                return try tx.saveOption(SelectOption(propertyId: multi.id, name: name, color: .blue, sortKey: key!))
            }
            return (options, tags)
        }
        self.base = base
        self.select = select
        self.multi = multi
        options = made.0
        tags = made.1
        text = try quiet.addProperty(to: base.databaseId, name: "Описание", kind: .text)
        number = try quiet.addProperty(to: base.databaseId, name: "Часы", kind: .number)
        check = try quiet.addProperty(to: base.databaseId, name: "Сделано", kind: .checkbox)
        date = try quiet.addProperty(to: base.databaseId, name: "Срок", kind: .date)
        // Строки: название, описание, часы, приоритет, теги, сделано, срок.
        let data: [(String, String?, Double?, Int?, [Int], Bool, String?)] = [
            ("Отчёт за месяц", "написать отчёт", 3, 0, [0], false, "2026-10-21"),
            ("Звонок", nil, 1, 1, [], true, "2026-10-22"),
            ("Бюджет", "согласовать", 5, 0, [0, 1], false, nil),
            ("Ремонт", nil, nil, 2, [1], true, "2026-11-02"),
            ("Альфа", "отчёт клиенту", 2, nil, [], false, "2026-10-21"),
            ("Яблоко", nil, 8, 1, [0], false, "2026-12-01"),
        ]
        for item in data {
            let row = try quiet.addRow(to: base.databaseId, in: nil, title: item.0)
            if let value = item.1 { try quiet.setCell(rowId: row, propertyId: text.id, value: ["runs": [], "string": .string(value)]) }
            if let value = item.2 { try quiet.setCell(rowId: row, propertyId: number.id, value: .number(value)) }
            if let value = item.3 { try quiet.setCell(rowId: row, propertyId: select.id, value: .string(options[value].id.databaseText)) }
            if !item.4.isEmpty { try quiet.setCell(rowId: row, propertyId: multi.id, value: .array(item.4.map { .string(tags[$0].id.databaseText) })) }
            if item.5 { try quiet.setCell(rowId: row, propertyId: check.id, value: .bool(true)) }
            if let value = item.6 { try quiet.setCell(rowId: row, propertyId: date.id, value: ["start": .string(value), "hasTime": false]) }
            rows.append(row)
        }
    }

    func step(_ body: () throws -> Void) rethrows {
        undo.beginUndoGrouping()
        try body()
        undo.endUndoGrouping()
    }

    func view(_ id: UUID? = nil) throws -> DatabaseView { try #require(try store.write { try $0.view(id ?? base.viewId) }) }
    func catalog() throws -> DatabaseCatalog { try DatabaseCatalog.read(base.databaseId, in: store) }
    func present(_ id: UUID? = nil, search: String? = nil) throws -> ViewPresentation {
        try #require(try ViewQuery.present(id ?? base.viewId, in: store, search: search,
                                           now: ISO8601DateFormatter().date(from: "2026-10-21T12:00:00Z")!))
    }
    func titles(_ ids: [UUID]) throws -> [String] { try store.write { tx in try ids.map { try tx.page($0)?.title ?? "?" } } }
    func shownTitles(_ id: UUID? = nil, search: String? = nil) throws -> [String] { try titles(try present(id, search: search).rowIds) }
    func optionKey(_ option: SelectOption) -> String { option.id.databaseText }
}
