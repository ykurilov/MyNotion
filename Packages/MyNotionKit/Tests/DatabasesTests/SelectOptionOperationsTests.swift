import Foundation
import GRDB
import Testing
@testable import Databases
@testable import NotesCore

/// Варианты выбора, множественного выбора и статуса (T065, spec US2, сценарии 1–3): создать из ячейки со случайным
/// цветом, переименовать, цвет, удалить из всех строк с ⌘Z, порядок и сортировка списка; статус — три группы и
/// варианты по умолчанию; одинаковые имена с двух Mac сливаются при правке ячейки (data-model.md, `db_select_option`).
@MainActor
@Suite("Операции баз: варианты (US2)")
struct SelectOptionOperationsTests {
    let folder: URL
    let store: NotesStore
    let undo = UndoManager()
    let operations: DatabaseOperations
    let quiet: DatabaseOperations
    let base: CreatedDatabase
    let rows: [UUID]

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("dbops-us2-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = NotesStore(database: try AppDatabase.open(at: folder.appendingPathComponent("MyNotion.sqlite")), clock: HybridLogicalClock(deviceId: UUID()))
        store.addWriteHook(CellIndexer())
        undo.groupsByEvent = false
        operations = DatabaseOperations(store: store, undoManager: undo)
        quiet = DatabaseOperations(store: store)
        base = try quiet.createDatabase(in: nil, isInline: false, title: "Задачи")
        rows = try (0..<3).map { _ in try quiet.addRow(to: base.databaseId, in: base.viewId, at: .bottom) }
    }

    func step(_ body: () throws -> Void) rethrows {
        undo.beginUndoGrouping()
        try body()
        undo.endUndoGrouping()
    }

    func read<T>(_ body: (NotesTransaction) throws -> T) throws -> T { try store.write { tx throws in try body(tx) } }
    func options(_ propertyId: UUID) throws -> [SelectOption] {
        try DatabaseCatalog.read(base.databaseId, in: store).options[propertyId] ?? []
    }
    func names(_ propertyId: UUID) throws -> [String] { try options(propertyId).map(\.name) }
    func cell(_ row: UUID, _ property: UUID) throws -> JSONValue? { try read { try $0.cell(rowId: row, propertyId: property)?.value } }
    func id(_ option: SelectOption) -> JSONValue { .string(option.id.databaseText) }

    // MARK: Создать из ячейки

    @Test("Enter в окне ячейки создаёт вариант и выбирает его одним шагом; цвет — один из 10, не как у предыдущего")
    func createFromCell() throws {
        let property = try quiet.addProperty(to: base.databaseId, name: "Тип", kind: .select)
        try step { _ = try operations.pickOption(named: "Баг", rowId: rows[0], propertyId: property.id) }
        let created = try #require(try options(property.id).first)
        #expect(created.name == "Баг")
        #expect(try cell(rows[0], property.id) == id(created))
        undo.undo()
        #expect(try names(property.id).isEmpty)
        #expect(try cell(rows[0], property.id) == nil)
        undo.redo()
        #expect(try names(property.id) == ["Баг"])

        // Тридцать вариантов подряд: каждый цвет — из палитры Notion и не как у предыдущего.
        for index in 0..<30 { _ = try quiet.createOption(in: property.id, named: "В\(index)") }
        let colors = try options(property.id).map(\.color)
        #expect(colors.allSatisfy { OptionColor(rawValue: $0) != nil })
        for (previous, next) in zip(colors, colors.dropFirst()) { #expect(previous != next) }
        #expect(Set(colors).count > 3)
    }

    @Test("Название уже есть — выбирается найденный вариант (без учёта регистра), новый не создаётся")
    func pickExistingByName() throws {
        let property = try quiet.addProperty(to: base.databaseId, name: "Тип", kind: .select)
        let bug = try quiet.createOption(in: property.id, named: "Баг")
        try quiet.pickOption(named: "баг", rowId: rows[1], propertyId: property.id)
        #expect(try names(property.id) == ["Баг"])
        #expect(try cell(rows[1], property.id) == id(bug))
    }

    @Test("Выбор заменяет значение; множественный — добавляет и снимает, порядок — порядок выбора")
    func pickReplacesOrToggles() throws {
        let select = try quiet.addProperty(to: base.databaseId, name: "Тип", kind: .select)
        let a = try quiet.createOption(in: select.id, named: "А")
        let b = try quiet.createOption(in: select.id, named: "Б")
        try quiet.pickOption(a.id, rowId: rows[0], propertyId: select.id)
        try quiet.pickOption(b.id, rowId: rows[0], propertyId: select.id)
        #expect(try cell(rows[0], select.id) == id(b))
        try quiet.removeOption(b.id, rowId: rows[0], propertyId: select.id)
        #expect(try cell(rows[0], select.id) == nil)

        let tags = try quiet.addProperty(to: base.databaseId, name: "Теги", kind: .multiSelect)
        let x = try quiet.createOption(in: tags.id, named: "Икс")
        let y = try quiet.createOption(in: tags.id, named: "Игрек")
        try step { try operations.pickOption(y.id, rowId: rows[0], propertyId: tags.id) }
        try step { try operations.pickOption(x.id, rowId: rows[0], propertyId: tags.id) }
        #expect(try cell(rows[0], tags.id) == .array([id(y), id(x)]))
        try step { try operations.pickOption(y.id, rowId: rows[0], propertyId: tags.id) }
        #expect(try cell(rows[0], tags.id) == .array([id(x)]))
        try step { try operations.removeOption(x.id, rowId: rows[0], propertyId: tags.id) }
        #expect(try cell(rows[0], tags.id) == nil)
        undo.undo()
        undo.undo()
        #expect(try cell(rows[0], tags.id) == .array([id(y), id(x)]))
    }

    // MARK: Меню «⋯» варианта

    @Test("Переименовать и цвет — по шагу ⌘Z; пустое имя не принимается")
    func renameAndColor() throws {
        let property = try quiet.addProperty(to: base.databaseId, name: "Тип", kind: .select)
        let option = try quiet.createOption(in: property.id, named: "Баг", color: .gray)
        try step { try operations.renameOption(option.id, to: "Ошибка") }
        try step { try operations.setOptionColor(option.id, to: .red) }
        #expect(try options(property.id).first?.name == "Ошибка")
        #expect(try options(property.id).first?.optionColor == .red)
        #expect(throws: (any Error).self) { try operations.renameOption(option.id, to: "   ") }
        undo.undo()
        #expect(try options(property.id).first?.optionColor == .gray)
        undo.undo()
        #expect(try options(property.id).first?.name == "Баг")
    }

    @Test("Удалить вариант — пропадает из всех строк; ⌘Z возвращает вариант и значения")
    func deleteFromAllRows() throws {
        let select = try quiet.addProperty(to: base.databaseId, name: "Тип", kind: .select)
        let bug = try quiet.createOption(in: select.id, named: "Баг")
        let task = try quiet.createOption(in: select.id, named: "Задача")
        let tags = try quiet.addProperty(to: base.databaseId, name: "Теги", kind: .multiSelect)
        let urgent = try quiet.createOption(in: tags.id, named: "Срочно")
        let later = try quiet.createOption(in: tags.id, named: "Потом")
        try quiet.setCell(rowId: rows[0], propertyId: select.id, value: id(bug))
        try quiet.setCell(rowId: rows[1], propertyId: select.id, value: id(bug))
        try quiet.setCell(rowId: rows[2], propertyId: select.id, value: id(task))
        try quiet.setCell(rowId: rows[0], propertyId: tags.id, value: [id(urgent), id(later)])
        try quiet.setCell(rowId: rows[1], propertyId: tags.id, value: [id(urgent)])

        try step { try operations.deleteOption(bug.id) }
        try step { try operations.deleteOption(urgent.id) }
        #expect(try names(select.id) == ["Задача"])
        #expect(try cell(rows[0], select.id) == nil)
        #expect(try cell(rows[1], select.id) == nil)
        #expect(try cell(rows[2], select.id) == id(task))
        #expect(try cell(rows[0], tags.id) == .array([id(later)]))
        #expect(try cell(rows[1], tags.id) == nil)

        undo.undo()
        #expect(try cell(rows[0], tags.id) == .array([id(urgent), id(later)]))
        #expect(try cell(rows[1], tags.id) == .array([id(urgent)]))
        undo.undo()
        #expect(try names(select.id) == ["Баг", "Задача"])
        #expect(try cell(rows[0], select.id) == id(bug))
        #expect(try cell(rows[1], select.id) == id(bug))
        undo.redo()
        #expect(try cell(rows[1], select.id) == nil)
    }

    // MARK: Порядок

    @Test("Перетащить вариант — новый порядок и сортировка строк по нему; ⌘Z — прежний")
    func moveOption() throws {
        let property = try quiet.addProperty(to: base.databaseId, name: "Тип", kind: .select)
        let a = try quiet.createOption(in: property.id, named: "А")
        let b = try quiet.createOption(in: property.id, named: "Б")
        let c = try quiet.createOption(in: property.id, named: "В")
        try step { try operations.moveOption(c.id, after: nil) }
        #expect(try names(property.id) == ["В", "А", "Б"])
        try step { try operations.moveOption(a.id, after: b.id) }
        #expect(try names(property.id) == ["В", "Б", "А"])
        try quiet.setCell(rowId: rows[0], propertyId: property.id, value: id(a))
        #expect(try DatabaseCatalog.read(base.databaseId, in: store).position(ofOption: a.id) == 2)
        let sortNumber = try store.database.dbWriter.read { db in
            try Double.fetchOne(db, sql: "SELECT sortNumber FROM db_cell WHERE rowId = ? AND propertyId = ?",
                                arguments: [rows[0].databaseText, property.id.databaseText])
        }
        #expect(sortNumber == 2)
        undo.undo()
        undo.undo()
        #expect(try names(property.id) == ["А", "Б", "В"])
    }

    @Test("Сортировка списка вариантов: вручную, по алфавиту, в обратном порядке — порядок хранения не меняется")
    func optionSort() throws {
        let property = try quiet.addProperty(to: base.databaseId, name: "Тип", kind: .select)
        for name in ["Банан", "яблоко", "Арбуз"] { _ = try quiet.createOption(in: property.id, named: name) }
        try step { try operations.setOptionSort(property.id, to: .alphabetical) }
        let catalog = try DatabaseCatalog.read(base.databaseId, in: store)
        let context = catalog.context(for: try #require(catalog.propertiesById[property.id]))
        #expect(OptionList.shown(in: context).map(\.name) == ["Арбуз", "Банан", "яблоко"])
        var reversed = context
        reversed.property.config["optionSort"] = "reverseAlphabetical"
        #expect(OptionList.shown(in: reversed).map(\.name) == ["яблоко", "Банан", "Арбуз"])
        #expect(try names(property.id) == ["Банан", "яблоко", "Арбуз"])
        undo.undo()
        #expect(try read { try $0.property(property.id)?.config["optionSort"] } == nil)
    }

    @Test("Поиск в окне: варианты по началу и части названия без учёта регистра; «Создать», если точного нет")
    func filterList() throws {
        let property = try quiet.addProperty(to: base.databaseId, name: "Тип", kind: .select)
        for name in ["Баг", "Задача", "Багфикс"] { _ = try quiet.createOption(in: property.id, named: name) }
        let catalog = try DatabaseCatalog.read(base.databaseId, in: store)
        let context = catalog.context(for: try #require(catalog.propertiesById[property.id]))
        #expect(OptionList.matching("баг", in: context).map(\.name) == ["Баг", "Багфикс"])
        #expect(OptionList.matching("", in: context).count == 3)
        #expect(OptionList.offersCreation("баг", in: context) == false)
        #expect(OptionList.offersCreation("Ба", in: context))
        #expect(OptionList.offersCreation("  ", in: context) == false)
    }

    // MARK: Статус

    @Test("Новый статус: три группы и варианты по умолчанию — «Не начато», «В работе», «Готово» с цветами Notion")
    func statusDefaults() throws {
        let status = try quiet.addProperty(to: base.databaseId, name: "Статус", kind: .status)
        let list = try options(status.id)
        #expect(list.map(\.name) == ["Не начато", "В работе", "Готово"])
        #expect(list.map(\.statusGroup) == [.todo, .inProgress, .complete])
        #expect(list.map(\.optionColor) == [.default, .blue, .green])
        #expect(StatusGroup.allCases.map(\.title) == ["К выполнению", "В работе", "Завершено"])
    }

    @Test("Статус: вариант из ячейки — в «К выполнению»; вариант в группу и перенос между группами")
    func statusGroups() throws {
        let status = try quiet.addProperty(to: base.databaseId, name: "Статус", kind: .status)
        let paused = try quiet.pickOption(named: "Отложено", rowId: rows[0], propertyId: status.id)
        #expect(paused.statusGroup == .todo)
        let review = try quiet.createOption(in: status.id, named: "На проверке", group: .inProgress)
        #expect(try names(status.id) == ["Не начато", "Отложено", "В работе", "На проверке", "Готово"])
        try step { try operations.moveOption(paused.id, after: review.id, group: .inProgress) }
        #expect(try options(status.id).first { $0.id == paused.id }?.statusGroup == .inProgress)
        #expect(try names(status.id) == ["Не начато", "В работе", "На проверке", "Отложено", "Готово"])
        undo.undo()
        #expect(try options(status.id).first { $0.id == paused.id }?.statusGroup == .todo)
    }

    // MARK: Два Mac

    @Test("Одинаковые имена с двух Mac: в списке — первый по id; правка ячейки переводит значение на него")
    func duplicatesMergeOnEdit() throws {
        let tags = try quiet.addProperty(to: base.databaseId, name: "Теги", kind: .multiSelect)
        let first = SelectOption(id: UUID(uuidString: "00000000-0000-7000-8000-000000000001")!, propertyId: tags.id, name: "Срочно",
                                 color: .red, sortKey: .between(nil, nil))
        let second = SelectOption(id: UUID(uuidString: "00000000-0000-7000-8000-000000000002")!, propertyId: tags.id, name: "Срочно",
                                  color: .blue, sortKey: .between(first.sortKey, nil))
        try store.write { tx throws in
            try tx.saveOption(second)
            try tx.saveOption(first)
        }
        let other = try quiet.createOption(in: tags.id, named: "Потом")
        try quiet.setCell(rowId: rows[0], propertyId: tags.id, value: [id(second)])
        let catalog = try DatabaseCatalog.read(base.databaseId, in: store)
        let context = catalog.context(for: try #require(catalog.propertiesById[tags.id]))
        #expect(OptionList.shown(in: context).map(\.id) == [first.id, other.id])

        try quiet.pickOption(other.id, rowId: rows[0], propertyId: tags.id)
        #expect(try cell(rows[0], tags.id) == .array([id(first), id(other)]))
        // Выбор второго из списка не бывает, но и он ведёт к первому.
        let select = try quiet.addProperty(to: base.databaseId, name: "Тип", kind: .select)
        let a = SelectOption(id: UUID(uuidString: "00000000-0000-7000-8000-00000000000A")!, propertyId: select.id, name: "Баг", sortKey: .between(nil, nil))
        let b = SelectOption(id: UUID(uuidString: "00000000-0000-7000-8000-00000000000B")!, propertyId: select.id, name: "баг", sortKey: .between(a.sortKey, nil))
        try store.write { tx throws in
            try tx.saveOption(a)
            try tx.saveOption(b)
        }
        try quiet.pickOption(b.id, rowId: rows[1], propertyId: select.id)
        #expect(try cell(rows[1], select.id) == id(a))
    }
}
