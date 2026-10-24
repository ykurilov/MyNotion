import Foundation
import Testing
import DatabaseGrid
@testable import DatabaseRowPage
@testable import Databases
@testable import NotesCore

/// Свойства страницы строки (T043, contracts/database-ui.md, «Страница строки»): какие свойства и в каком порядке,
/// «Пусто», как правится каждое и что пишется из поля правки.
@MainActor
@Suite("Страница строки: свойства")
struct RowPropertiesTests {
    let folder: URL
    let store: NotesStore
    let operations: DatabaseOperations
    let database: CreatedDatabase
    let rowId: UUID

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("rowpage-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = NotesStore(database: try AppDatabase.open(at: folder.appendingPathComponent("MyNotion.sqlite")), clock: HybridLogicalClock(deviceId: UUID()))
        operations = DatabaseOperations(store: store)
        database = try operations.createDatabase(in: nil, isInline: false, title: "Задачи")
        rowId = try operations.addRow(to: database.databaseId, in: database.viewId, title: "Купить молоко")
    }

    private func add(_ name: String, _ kind: PropertyKind) throws -> DatabaseProperty {
        try operations.addProperty(to: database.databaseId, name: name, kind: kind)
    }

    private func page() throws -> RowPage { try #require(try RowPage.read(rowId, in: store)) }

    @Test("Обычная страница и сама база — не строки")
    func notRows() throws {
        let plain = try store.write { tx throws in try tx.createPage(title: "Проект") }
        #expect(try RowPage.read(plain.id, in: store) == nil)
        #expect(try RowPage.read(database.databaseId, in: store) == nil)
        #expect(try RowPage.read(UUID(), in: store) == nil)
    }

    @Test("Свойства под названием — все, кроме «Названия», по порядку базы (sortKey); удалённых нет")
    func orderAndTitle() throws {
        let number = try add("Число", .number)
        let done = try add("Готово", .checkbox)
        let gone = try add("Старое", .text)
        try operations.setDeleted(gone.id, true)
        // Свойство с ключом раньше первого — встаёт первым, хотя создано последним.
        let first = try store.write { tx throws in
            let keys = try tx.properties(ofDatabase: database.databaseId).map(\.sortKey)
            return try tx.saveProperty(DatabaseProperty(databaseId: database.databaseId, name: "Срок", kind: .date, sortKey: .between(nil, keys.min())))
        }
        let lines = try page().lines
        #expect(lines.map(\.propertyId) == [first.id, number.id, done.id])
        #expect(lines.map(\.name) == ["Срок", "Число", "Готово"])
        #expect(lines.map(\.symbol) == [CellKind.for(.date).symbol, CellKind.for(.number).symbol, CellKind.for(.checkbox).symbol])
    }

    @Test("Пустое значение — «Пусто», заполненное — показ ячейки")
    func emptyAndFilled() throws {
        let number = try add("Число", .number)
        let text = try add("Заметка", .text)
        try operations.setCell(rowId: rowId, propertyId: number.id, value: .number(5))
        let lines = try page().lines
        let numberLine = try #require(lines.first { $0.propertyId == number.id })
        let textLine = try #require(lines.first { $0.propertyId == text.id })
        #expect(numberLine.presentation == .text("5") && !numberLine.isEmpty)
        #expect(textLine.presentation == .empty && textLine.isEmpty)
        #expect(RowPropertyLine.emptyText == "Пусто")
    }

    @Test("Как правится: поле — текст, число, ссылка, email, телефон; щелчок — флажок; окно — выбор, статус, дата, файлы, связь; без правки — ID, время, формула, сводка")
    func editingKinds() throws {
        let kinds: [PropertyKind] = [.text, .number, .url, .email, .phone, .checkbox, .select, .multiSelect, .status, .date, .files, .relation,
                                     .uniqueId, .createdTime, .lastEditedTime, .formula, .rollup]
        var expected: [String: RowPropertyEditing] = [:]
        for kind in kinds {
            let config: JSONValue = kind == .formula ? ["expression": "1"] : .emptyObject
            _ = try operations.addProperty(to: database.databaseId, name: kind.rawValue, kind: kind, config: config)
            switch kind {
            case .text, .number, .url, .email, .phone: expected[kind.rawValue] = .field
            case .checkbox: expected[kind.rawValue] = .toggle
            case .select, .multiSelect, .status, .date, .files, .relation: expected[kind.rawValue] = .popup
            default: expected[kind.rawValue] = .readOnly
            }
        }
        let lines = try page().lines
        #expect(lines.count == kinds.count)
        for line in lines { #expect(line.editing == expected[line.name], "\(line.name)") }
    }

    @Test("Поле правки: текст значения в поле и значение из набранного; пустое — стереть")
    func fieldRoundTrip() throws {
        let number = try add("Число", .number)
        let text = try add("Заметка", .text)
        let url = try add("Сайт", .url)
        try operations.setCell(rowId: rowId, propertyId: number.id, value: .number(2.5))
        try operations.setCell(rowId: rowId, propertyId: text.id, value: ["runs": [], "string": "Привет"])
        let page = try page()
        #expect(page.editText(of: number.id) == "2.5")
        #expect(page.editText(of: text.id) == "Привет")
        #expect(page.editText(of: url.id) == "")
        #expect(page.value(fromText: "42", for: number.id) == .number(42))
        #expect(page.value(fromText: "  ", for: number.id) == nil)
        #expect(page.value(fromText: "Пока", for: text.id)?["string"]?.string == "Пока")
        #expect(page.value(fromText: "", for: text.id) == nil)
        #expect(page.value(fromText: " kurilov.cloud ", for: url.id) == .string("kurilov.cloud"))
    }

    @Test("Флажок: щелчок ставит и снимает")
    func toggle() throws {
        let done = try add("Готово", .checkbox)
        #expect(try page().toggledValue(of: done.id) == .bool(true))
        try operations.setCell(rowId: rowId, propertyId: done.id, value: .bool(true))
        let line = try #require(try page().lines.first { $0.propertyId == done.id })
        #expect(line.presentation == .checkbox(true))
        #expect(try page().toggledValue(of: done.id) == .bool(false))
    }
}
