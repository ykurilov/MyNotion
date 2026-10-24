import Foundation
import Testing
@testable import Databases
@testable import NotesCore

/// Операции US1 (T031, research R11): свойства, колонки вида, строки, ячейки, смена типа — каждая правка один шаг ⌘Z,
/// ⇧⌘Z повторяет.
@MainActor
@Suite("Операции баз: таблица (US1)")
struct DatabaseOperationsTests {
    let folder: URL
    let store: NotesStore
    let undo = UndoManager()
    let operations: DatabaseOperations
    /// Подготовка без шагов отмены (с `groupsByEvent = false` шаг вне группы роняет `registerUndo`).
    let quiet: DatabaseOperations
    let base: CreatedDatabase

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("dbops-us1-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = NotesStore(database: try AppDatabase.open(at: folder.appendingPathComponent("MyNotion.sqlite")), clock: HybridLogicalClock(deviceId: UUID()))
        store.addWriteHook(CellIndexer())
        undo.groupsByEvent = false
        operations = DatabaseOperations(store: store, undoManager: undo)
        quiet = DatabaseOperations(store: store)
        base = try quiet.createDatabase(in: nil, isInline: false, title: "Задачи")
    }

    func step(_ body: () throws -> Void) rethrows {
        undo.beginUndoGrouping()
        try body()
        undo.endUndoGrouping()
    }

    func read<T>(_ body: (NotesTransaction) throws -> T) throws -> T { try store.write { tx throws in try body(tx) } }
    func propertyNames() throws -> [String] { try read { try $0.properties(ofDatabase: base.databaseId).map(\.name) } }
    func columns() throws -> [UUID] {
        let view = try #require(try read { try $0.view(base.viewId) })
        let catalog = try DatabaseCatalog.read(base.databaseId, in: store)
        return ViewQuery.visiblePropertyIds(of: view, catalog: catalog)
    }
    func width(_ propertyId: UUID) throws -> Double? {
        let view = try #require(try read { try $0.view(base.viewId) })
        return (view.columns.array ?? []).first { $0["propertyId"]?.string == propertyId.databaseText }?["width"]?.number
    }
    func rowOrder() throws -> [UUID] { try #require(try ViewQuery.open(base.viewId, in: store)).result.rowIds }
    func text(_ string: String) -> JSONValue { ["runs": [], "string": .string(string)] }
    func cellText(_ row: UUID, _ property: UUID) throws -> String? {
        try read { try $0.cell(rowId: row, propertyId: property)?.value }.flatMap { $0["string"]?.string ?? $0.string }
    }

    // MARK: Свойства

    @Test("Новая база: пустая, одна колонка «Название» шириной 280, строк нет")
    func emptyDatabase() throws {
        #expect(try propertyNames() == ["Название"])
        #expect(try columns() == [base.titlePropertyId])
        #expect(try width(base.titlePropertyId) == 280)
        #expect(try rowOrder().isEmpty)
    }

    @Test("Переименовать свойство — один шаг; пустое имя не принимается")
    func rename() throws {
        let property = try quiet.addProperty(to: base.databaseId, name: "Текст", kind: .text)
        try step { try operations.renameProperty(property.id, to: "Заметки") }
        #expect(try propertyNames() == ["Название", "Заметки"])
        #expect(throws: (any Error).self) { try operations.renameProperty(property.id, to: "  ") }
        undo.undo()
        #expect(try propertyNames() == ["Название", "Текст"])
        undo.redo()
        #expect(try propertyNames() == ["Название", "Заметки"])
    }

    @Test("Переставить колонку — только в этом виде; «Название» остаётся первой; ширина — протяжкой, не уже 100")
    func moveAndResize() throws {
        let a = try quiet.addProperty(to: base.databaseId, name: "А", kind: .text)
        let b = try quiet.addProperty(to: base.databaseId, name: "Б", kind: .number)
        let c = try quiet.addProperty(to: base.databaseId, name: "В", kind: .checkbox)
        #expect(try columns() == [base.titlePropertyId, a.id, b.id, c.id])
        try step { try operations.moveColumn(c.id, in: base.viewId, to: 1) }
        #expect(try columns() == [base.titlePropertyId, c.id, a.id, b.id])
        try step { try operations.moveColumn(b.id, in: base.viewId, to: 0) }
        #expect(try columns() == [base.titlePropertyId, b.id, c.id, a.id], "перед «Названием» колонку не поставить")
        // Без изменений шага отмены нет (вне группы шаг уронил бы `registerUndo`).
        try operations.moveColumn(base.titlePropertyId, in: base.viewId, to: 3)
        #expect(try columns().first == base.titlePropertyId, "«Название» не переставляется")
        #expect(try read { try $0.properties(ofDatabase: base.databaseId).map(\.id) } == [base.titlePropertyId, a.id, b.id, c.id],
                "порядок свойств базы не трогается")
        undo.undo()
        #expect(try columns() == [base.titlePropertyId, c.id, a.id, b.id])
        undo.undo()
        #expect(try columns() == [base.titlePropertyId, a.id, b.id, c.id])

        try step { try operations.setColumnWidth(a.id, in: base.viewId, to: 320) }
        #expect(try width(a.id) == 320)
        try step { try operations.setColumnWidth(a.id, in: base.viewId, to: 20) }
        #expect(try width(a.id) == DatabaseColumns.minimumWidth)
        undo.undo()
        #expect(try width(a.id) == 320)
        undo.undo()
        #expect(try width(a.id) == nil, "до протяжки ширина — по умолчанию")
    }

    @Test("Вставить слева и справа: текстовое «Свойство», «Свойство 1» рядом с колонкой; ⌘Z — в «Удалённые свойства»")
    func insertBeside() throws {
        let a = try quiet.addProperty(to: base.databaseId, name: "А", kind: .number)
        var left: DatabaseProperty!
        var right: DatabaseProperty!
        try step { left = try operations.insertProperty(beside: a.id, side: .left, in: base.viewId) }
        try step { right = try operations.insertProperty(beside: a.id, side: .right, in: base.viewId) }
        #expect(left.name == "Свойство" && left.kind == .text)
        #expect(right.name == "Свойство 1")
        #expect(try columns() == [base.titlePropertyId, left.id, a.id, right.id])
        try step { _ = try operations.insertProperty(beside: base.titlePropertyId, side: .left, in: base.viewId) }
        #expect(try columns()[0] == base.titlePropertyId && columns()[1] != left.id, "слева от «Названия» — значит справа от него")
        undo.undo()
        undo.undo()
        #expect(try columns() == [base.titlePropertyId, left.id, a.id])
        #expect(try read { try $0.property(right.id)?.deletedAt } != nil)
        undo.redo()
        #expect(try columns() == [base.titlePropertyId, left.id, a.id, right.id])
    }

    @Test("Дублировать свойство: «А (1)» справа, со значениями и вариантами; ⌘Z убирает копию")
    func duplicate() throws {
        let a = try quiet.addProperty(to: base.databaseId, name: "А", kind: .text)
        let rows = try (0..<3).map { _ in try quiet.addRow(to: base.databaseId, in: base.viewId) }
        for (index, row) in rows.enumerated() { try quiet.setCell(rowId: row, propertyId: a.id, value: text("т\(index)")) }
        let other = try quiet.addProperty(to: base.databaseId, name: "Б", kind: .checkbox)
        var copy: DatabaseProperty!
        try step { copy = try operations.duplicateProperty(a.id, in: base.viewId) }
        #expect(copy.name == "А (1)" && copy.kind == .text)
        #expect(try columns() == [base.titlePropertyId, a.id, copy.id, other.id])
        #expect(try propertyNames() == ["Название", "А", "А (1)", "Б"])
        #expect(try rows.map { try cellText($0, copy.id) } == ["т0", "т1", "т2"])
        undo.undo()
        #expect(try propertyNames() == ["Название", "А", "Б"])
        undo.redo()
        #expect(try propertyNames() == ["Название", "А", "А (1)", "Б"])
        #expect(try cellText(rows[1], copy.id) == "т1")
    }

    @Test("Удалить — в «Удалённые свойства» со значениями, вернуть; удалить навсегда — значения стёрты, ⌘Z возвращает")
    func deleteRestoreErase() throws {
        let a = try quiet.addProperty(to: base.databaseId, name: "А", kind: .text)
        let row = try quiet.addRow(to: base.databaseId, in: base.viewId)
        try quiet.setCell(rowId: row, propertyId: a.id, value: text("значение"))
        try step { try operations.setDeleted(a.id, true) }
        #expect(try propertyNames() == ["Название"])
        #expect(try DatabaseCatalog.deletedProperties(of: base.databaseId, in: store).map(\.id) == [a.id])
        #expect(try cellText(row, a.id) == "значение", "значения хранятся")
        try step { try operations.setDeleted(a.id, false) }
        #expect(try propertyNames() == ["Название", "А"])
        try step { try operations.setDeleted(a.id, true) }

        try step { try operations.eraseProperty(a.id) }
        #expect(try DatabaseCatalog.deletedProperties(of: base.databaseId, in: store).isEmpty)
        #expect(try cellText(row, a.id) == nil)
        #expect(throws: (any Error).self) { try operations.setDeleted(a.id, false) }
        undo.undo()
        #expect(try DatabaseCatalog.deletedProperties(of: base.databaseId, in: store).map(\.id) == [a.id])
        #expect(try cellText(row, a.id) == "значение")
        undo.redo()
        #expect(try cellText(row, a.id) == nil)
        #expect(throws: (any Error).self) { try operations.setDeleted(base.titlePropertyId, true) }
    }

    @Test("Смена типа: текст → число переводит значения, ⌘Z возвращает тип и все значения одним шагом, ⇧⌘Z — снова")
    func changeType() throws {
        let a = try quiet.addProperty(to: base.databaseId, name: "Часы", kind: .text)
        let rows = try (0..<3).map { _ in try quiet.addRow(to: base.databaseId, in: base.viewId) }
        for (row, value) in zip(rows, ["12", "3,5", "много"]) { try quiet.setCell(rowId: row, propertyId: a.id, value: text(value)) }
        try step { try operations.changeType(a.id, to: .number) }
        #expect(try read { try $0.property(a.id)?.kind } == .number)
        #expect(try rows.map { row in try read { try $0.cell(rowId: row, propertyId: a.id)?.value } } == [.number(12), .number(3.5), nil])
        undo.undo()
        #expect(try read { try $0.property(a.id)?.kind } == .text)
        #expect(try rows.map { try cellText($0, a.id) } == ["12", "3,5", "много"])
        undo.redo()
        #expect(try read { try $0.cell(rowId: rows[0], propertyId: a.id)?.value } == .number(12))
        #expect(throws: (any Error).self) { try operations.changeType(base.titlePropertyId, to: .text) }
    }

    @Test("Смена типа: текст → множественный выбор создаёт варианты по названиям; ⌘Z убирает и их")
    func changeTypeToOptions() throws {
        let a = try quiet.addProperty(to: base.databaseId, name: "Метки", kind: .text)
        let rows = try (0..<2).map { _ in try quiet.addRow(to: base.databaseId, in: base.viewId) }
        try quiet.setCell(rowId: rows[0], propertyId: a.id, value: text("дом, сад"))
        try quiet.setCell(rowId: rows[1], propertyId: a.id, value: text("сад"))
        try step { try operations.changeType(a.id, to: .multiSelect) }
        let options = try read { try $0.options(ofProperty: a.id) }
        #expect(options.map(\.name) == ["дом", "сад"])
        #expect(Set(options.map(\.color)).count == 2, "цвета по кругу")
        let ids = Dictionary(uniqueKeysWithValues: options.map { ($0.name, JSONValue.string($0.id.databaseText)) })
        #expect(try read { try $0.cell(rowId: rows[0], propertyId: a.id)?.value } == .array([ids["дом"]!, ids["сад"]!]))
        #expect(try read { try $0.cell(rowId: rows[1], propertyId: a.id)?.value } == .array([ids["сад"]!]))
        undo.undo()
        #expect(try read { try $0.options(ofProperty: a.id) }.isEmpty)
        #expect(try cellText(rows[0], a.id) == "дом, сад")
    }

    // MARK: Строки

    @Test("«+ Новая строка» — в конце, «Создать» — вверху вида; ⌘Z — в корзину, ⇧⌘Z — обратно")
    func addRows() throws {
        var first: UUID!, second: UUID!, top: UUID!
        try step { first = try operations.addRow(to: base.databaseId, in: base.viewId) }
        try step { second = try operations.addRow(to: base.databaseId, in: base.viewId, title: "Вторая") }
        try step { top = try operations.addRow(to: base.databaseId, in: base.viewId, at: .top) }
        #expect(try rowOrder() == [top, first, second])
        #expect(try read { try $0.page(second)?.title } == "Вторая")
        #expect(try read { try $0.page(first)?.parentId } == base.databaseId)
        var below: UUID!
        try step { below = try operations.addRow(to: base.databaseId, in: base.viewId, at: .after(top)) }
        #expect(try rowOrder() == [top, below, first, second])
        undo.undo()
        undo.undo()
        #expect(try rowOrder() == [first, second])
        #expect(try read { try $0.page(top)?.trashedAt } != nil)
        undo.redo()
        #expect(try rowOrder() == [top, first, second])
    }

    @Test("Дублировать строку: копия ниже, название «(1)», значения ячеек; в корзину — ⌘Z возвращает")
    func duplicateAndTrash() throws {
        let a = try quiet.addProperty(to: base.databaseId, name: "А", kind: .text)
        let first = try quiet.addRow(to: base.databaseId, in: base.viewId, title: "Купить")
        let last = try quiet.addRow(to: base.databaseId, in: base.viewId, title: "Продать")
        try quiet.setCell(rowId: first, propertyId: a.id, value: text("молоко"))
        var copies: [UUID] = []
        try step { copies = try operations.duplicateRows([first], in: base.viewId) }
        #expect(try rowOrder() == [first, copies[0], last])
        #expect(try read { try $0.page(copies[0])?.title } == "Купить (1)")
        #expect(try cellText(copies[0], a.id) == "молоко")
        try step { try operations.trashRows([first, last]) }
        #expect(try rowOrder() == [copies[0]])
        #expect(try cellText(first, a.id) == "молоко", "корзина ячейки не трогает")
        undo.undo()
        #expect(try rowOrder() == [first, copies[0], last])
        undo.undo()
        #expect(try rowOrder() == [first, last])
    }

    @Test("Перетащить строку: меняется только ручной порядок этого вида")
    func dragRow() throws {
        let rows = try (0..<4).map { try quiet.addRow(to: base.databaseId, in: base.viewId, title: "\($0)") }
        let other = try read { tx throws in
            try tx.saveView(DatabaseView(databaseId: base.databaseId, name: "Таблица (1)", sortKey: .between(nil, nil))).id
        }
        let pageKeys = try read { tx in try rows.map { try tx.page($0)!.sortKey } }
        try step { try operations.moveRows([rows[3]], in: base.viewId, between: rows[0], and: rows[1]) }
        #expect(try rowOrder() == [rows[0], rows[3], rows[1], rows[2]])
        try step { try operations.moveRows([rows[0]], in: base.viewId, between: rows[2], and: nil) }
        #expect(try rowOrder() == [rows[3], rows[1], rows[2], rows[0]])
        #expect(try #require(try ViewQuery.open(other, in: store)).result.rowIds == rows, "в другом виде порядок прежний")
        #expect(try read { tx in try rows.map { try tx.page($0)!.sortKey } } == pageKeys, "место страницы не трогается")
        undo.undo()
        #expect(try rowOrder() == [rows[0], rows[3], rows[1], rows[2]])
        undo.undo()
        #expect(try rowOrder() == rows)
    }

    // MARK: Ячейки

    @Test("Запись блока ячеек: названия и значения, новые строки в конце — один шаг отмены")
    func writeCells() throws {
        let a = try quiet.addProperty(to: base.databaseId, name: "А", kind: .text)
        let row = try quiet.addRow(to: base.databaseId, in: base.viewId, title: "Было")
        try quiet.setCell(rowId: row, propertyId: a.id, value: text("было"))
        var appended: [UUID] = []
        try step {
            appended = try operations.writeCells([
                CellWrite(row: .existing(row), propertyId: base.titlePropertyId, value: .string("Стало")),
                CellWrite(row: .existing(row), propertyId: a.id, value: text("стало")),
                CellWrite(row: .appended(0), propertyId: base.titlePropertyId, value: .string("Новая")),
                CellWrite(row: .appended(1), propertyId: a.id, value: text("новая 2")),
            ], appendingRows: 2, to: base.databaseId, in: base.viewId)
        }
        #expect(appended.count == 2)
        #expect(try rowOrder() == [row] + appended)
        #expect(try read { try $0.page(row)?.title } == "Стало")
        #expect(try read { try $0.page(appended[0])?.title } == "Новая")
        #expect(try cellText(appended[1], a.id) == "новая 2")
        undo.undo()
        #expect(try rowOrder() == [row])
        #expect(try read { try $0.page(row)?.title } == "Было")
        #expect(try cellText(row, a.id) == "было")
        undo.redo()
        #expect(try rowOrder() == [row] + appended)
        #expect(try read { try $0.page(row)?.title } == "Стало")
        #expect(try cellText(appended[1], a.id) == "новая 2")
    }
}
