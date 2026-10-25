import Foundation
import GRDB
import Reminders
import Testing
@testable import Databases
@testable import NotesCore

/// Индексатор ячеек (T016, research R3, R14, R16): сравнимые колонки, строки поиска и напоминания дат — в той же
/// транзакции, что правка.
@Suite("Индексатор ячеек")
struct CellIndexerTests {
    let folder: URL
    let store: NotesStore
    let database: UUID
    let text: UUID, select: UUID, date: UUID
    let row: UUID
    let low: SelectOption, high: SelectOption

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("indexer-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = NotesStore(database: try AppDatabase.open(at: folder.appendingPathComponent("MyNotion.sqlite")), clock: HybridLogicalClock(deviceId: UUID()))
        store.addWriteHook(CellIndexer())
        store.addWriteHook(ReminderIndexer())
        var made: (UUID, UUID, UUID, UUID, UUID, SelectOption, SelectOption)!
        try store.write { tx throws in
            let page = try tx.createPage(title: "Задачи")
            try tx.saveDatabase(DatabaseSchema(pageId: page.id))
            try tx.saveProperty(DatabaseProperty(databaseId: page.id, name: "Название", kind: .title, sortKey: FractionalSortKey(rawValue: "a")!))
            let text = try tx.saveProperty(DatabaseProperty(databaseId: page.id, name: "Описание", kind: .text, sortKey: FractionalSortKey(rawValue: "b")!))
            let select = try tx.saveProperty(DatabaseProperty(databaseId: page.id, name: "Приоритет", kind: .select, sortKey: FractionalSortKey(rawValue: "c")!))
            let date = try tx.saveProperty(DatabaseProperty(databaseId: page.id, name: "Срок", kind: .date, sortKey: FractionalSortKey(rawValue: "d")!))
            let low = try tx.saveOption(SelectOption(propertyId: select.id, name: "Низкий", sortKey: FractionalSortKey(rawValue: "a")!))
            let high = try tx.saveOption(SelectOption(propertyId: select.id, name: "Высокий", sortKey: FractionalSortKey(rawValue: "b")!))
            let row = try tx.createPage(title: "Позвонить в Банк", parentId: page.id)
            made = (page.id, text.id, select.id, date.id, row.id, low, high)
        }
        (database, text, select, date, row, low, high) = made
    }

    func columns(_ property: UUID, table: String = "db_cell") throws -> (String?, Double?, String?) {
        try store.database.dbWriter.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT sortText, sortNumber, searchText FROM \(table) WHERE rowId = ? AND propertyId = ?",
                                             arguments: [row.databaseText, property.databaseText]) else { return (nil, nil, nil) }
            return (row[0], row[1], row[2])
        }
    }

    @Test("Сравнимые колонки пишутся в той же транзакции, что ячейка; пустая — без колонок")
    func writesComparables() throws {
        try store.write { tx in try tx.setCell(rowId: row, propertyId: text, value: ["runs": [], "string": "Ёлка Café"]) }
        #expect(try columns(text) == ("елка cafe", nil, "елка cafe"))
        try store.write { tx in try tx.setCell(rowId: row, propertyId: text, value: nil) }
        #expect(try columns(text) == (nil, nil, nil))
    }

    @Test("Выбор: место варианта; перестановка вариантов переписывает места; вариант пришёл позже ячейки")
    func optionPositions() throws {
        try store.write { tx in try tx.setCell(rowId: row, propertyId: select, value: .string(high.id.databaseText)) }
        #expect(try columns(select).1 == 1)
        try store.write { tx throws in
            var moved = high
            moved.sortKey = FractionalSortKey(rawValue: "0V")!
            try tx.saveOption(moved)
        }
        #expect(try columns(select).1 == 0, "место варианта сменилось — ячейка перезаписана")
        let late = SelectOption(propertyId: select, name: "Поздний", sortKey: FractionalSortKey(rawValue: "z")!)
        try store.write { tx in try tx.setCell(rowId: row, propertyId: select, value: .string(late.id.databaseText)) }
        #expect(try columns(select).0 == nil)
        try store.write { tx in try tx.saveOption(late) }
        #expect(try columns(select).0 == late.id.databaseText)
    }

    @Test("Смена типа свойства переписывает колонки всех его ячеек")
    func typeChangeReindexes() throws {
        try store.write { tx in try tx.setCell(rowId: row, propertyId: text, value: .number(12)) }
        try store.write { tx throws in
            var property = try #require(try tx.property(text))
            property.kind = .number
            try tx.saveProperty(property)
        }
        #expect(try columns(text).1 == 12)
    }

    @Test("Название строки — сравнимое в `db_computed` свойства «Название»")
    func titleComparables() throws {
        let title = try store.write { tx in try tx.properties(ofDatabase: database).first { $0.kind == .title }!.id }
        #expect(try columns(title, table: "db_computed").0 == "позвонить в банк")
        try store.write { tx throws in
            var page = try #require(try tx.page(row))
            page.title = "Ёж"
            try tx.updatePage(page)
        }
        #expect(try columns(title, table: "db_computed").0 == "еж")
    }

    @Test("Текстовое значение — строка `search_index` страницы-строки; пустое — убирается")
    func searchIndexRows() throws {
        try store.write { tx in try tx.setCell(rowId: row, propertyId: text, value: ["runs": [], "string": "квитанция за свет"]) }
        func hits() throws -> [String] {
            try store.database.dbWriter.read { db in
                try String.fetchAll(db, sql: "SELECT pageId FROM search_index WHERE search_index MATCH ?", arguments: ["квитанция"])
            }
        }
        #expect(try hits() == [row.databaseText])
        try store.write { tx in try tx.setCell(rowId: row, propertyId: text, value: nil) }
        #expect(try hits().isEmpty)
    }

    @Test("Текст сменил тип на нетекстовый — старое значение пропадает из поиска страниц")
    func typeChangeDropsSearchRows() throws {
        try store.write { tx in try tx.setCell(rowId: row, propertyId: text, value: ["runs": [], "string": "квитанция за свет"]) }
        try store.write { tx throws in
            var property = try #require(try tx.property(text))
            property.kind = .number
            try tx.saveProperty(property)
        }
        let hits = try store.database.dbWriter.read { db in
            try String.fetchAll(db, sql: "SELECT pageId FROM search_index WHERE search_index MATCH ?", arguments: ["квитанция"])
        }
        #expect(hits.isEmpty)
    }

    @MainActor
    @Test("Дата с напоминанием — в индексе напоминаний 002; без напоминания и в корзине — нет")
    func dateReminders() throws {
        try store.write { tx throws in
            try tx.setCell(rowId: row, propertyId: date, value: ["start": "2030-05-10T15:00", "hasTime": true, "timeZone": "Europe/Moscow",
                                                                 "reminder": "minutes30"])
        }
        func fireAt() throws -> Date? {
            try store.database.dbWriter.read { db in
                try Date.fetchOne(db, sql: "SELECT fireAt FROM reminder_index WHERE pageId = ?", arguments: [row.databaseText])
            }
        }
        let expected = DateText.parse("2030-05-10T14:30", timeZone: "Europe/Moscow")!
        #expect(try fireAt() == expected)
        try store.write { tx throws in
            try tx.setCell(rowId: row, propertyId: date, value: ["start": "2030-05-10", "hasTime": false, "timeZone": "Europe/Moscow", "reminder": "day1"])
        }
        #expect(try fireAt() == DateText.parse("2030-05-09T09:00", timeZone: "Europe/Moscow"), "без времени — за день в 9:00")
        try PageTreeOperationsForTests.trash(row, store: store)
        #expect(try fireAt() == nil)
    }
}

@MainActor
enum PageTreeOperationsForTests {
    static func trash(_ pageId: UUID, store: NotesStore) throws {
        try PageTreeOperations(store: store).moveToTrash(pageId)
    }
}
