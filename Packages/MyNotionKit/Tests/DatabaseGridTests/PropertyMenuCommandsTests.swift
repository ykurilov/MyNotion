import Foundation
import Testing
@testable import Databases
@testable import DatabaseGrid
@testable import NotesCore

/// Меню колонки, список типов, панель «Изменить свойство» и окно «Свойства» базы (T039, contracts/database-ui.md):
/// какие пункты показываются, что делает пункт, поиск и клавиши списка типов, перестановка и «Удалённые свойства».
@MainActor
@Suite("Меню колонки и окна свойства (US1)")
struct PropertyMenuCommandsTests {
    let store: NotesStore
    let operations: DatabaseOperations
    let base: CreatedDatabase

    init() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("propmenu-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = NotesStore(database: try AppDatabase.open(at: folder.appendingPathComponent("MyNotion.sqlite")), clock: HybridLogicalClock(deviceId: UUID()))
        operations = DatabaseOperations(store: store)
        base = try operations.createDatabase(in: nil, isInline: false, title: "Задачи")
    }

    var commands: PropertyMenuCommands { PropertyMenuCommands(store: store, operations: operations, databaseId: base.databaseId, viewId: base.viewId) }
    func catalog() throws -> DatabaseCatalog { try DatabaseCatalog.read(base.databaseId, in: store) }
    func names() throws -> [String] { try catalog().properties.map(\.name) }
    func property(_ name: String) throws -> DatabaseProperty { try #require(try catalog().properties.first { $0.name == name }) }
    func columns() throws -> [UUID] {
        let view = try #require(try store.write { try $0.view(base.viewId) })
        return ViewQuery.visiblePropertyIds(of: view, catalog: try catalog())
    }

    // MARK: Пункты

    @Test("Пункты US1 и вида (US3): фильтр, сортировка, группировка, посчитать, скрыть, перенос — в средней группе")
    func us1Entries() throws {
        let text = try operations.addProperty(to: base.databaseId, name: "Заметка", kind: .text)
        #expect(commands.entries(for: text).map(\.title) == [
            "Изменить свойство", "Сменить тип", "—", "Фильтр", "Сортировка", "Группировка", "Посчитать", "Скрыть", "Переносить текст", "—",
            "Вставить слева", "Вставить справа", "Дублировать свойство", "Удалить свойство",
        ])
        // Колонка с переносом — «Не переносить текст».
        try operations.setWrap(text.id, true, in: base.viewId)
        #expect(commands.entries(for: text).map(\.title).contains("Не переносить текст"))
    }

    @Test("Пункты вида: «Фильтр» — плашка и её окно, «Скрыть», «Группировка», перенос; «Сортировка ›» и «Посчитать ›» — подменю")
    func viewEntries() throws {
        let text = try operations.addProperty(to: base.databaseId, name: "Заметка", kind: .text)
        #expect(try commands.perform(.filter, on: text) == .openFilter([0]))
        #expect(try commands.perform(.sort, on: text) == .openSortMenu)
        #expect(try commands.perform(.calculate, on: text) == .openCalculateMenu)
        #expect(try commands.perform(.hide, on: text) == .done)
        #expect(try !columns().contains(text.id))
        #expect(try commands.perform(.group, on: text) == .done)
        #expect(try commands.perform(.wrap, on: text) == .done)
        let view = try #require(try store.write { try $0.view(base.viewId) })
        #expect(view.groupSettings?.propertyId == text.id)
        #expect(view.wraps(text.id))
        #expect(view.filterNode?.ruleCount == 1)
    }

    @Test("«Название»: тип не меняется, не дублируется и не удаляется; без вида вставки нет")
    func titleAndNoView() throws {
        let title = try property("Название")
        #expect(commands.entries(for: title).map(\.title) == ["Изменить свойство", "—", "Фильтр", "Сортировка", "Группировка", "Посчитать",
                                                               "Переносить текст", "—", "Вставить слева", "Вставить справа"])
        let text = try operations.addProperty(to: base.databaseId, name: "Заметка", kind: .text)
        let noView = PropertyMenuCommands(store: store, operations: operations, databaseId: base.databaseId, viewId: nil)
        #expect(noView.entries(for: text).map(\.title) == ["Изменить свойство", "Сменить тип", "—", "Дублировать свойство", "Удалить свойство"])
    }

    // MARK: Действия пунктов

    @Test("Вставить слева и справа — «Свойство» рядом с колонкой; окна пунктов — у презентера")
    func insertBeside() throws {
        let note = try operations.addProperty(to: base.databaseId, name: "Заметка", kind: .text)
        // Как у Notion: новая колонка сразу открывает окно имени и типа под собой.
        guard case .configureNew(let right) = try commands.perform(.insertRight, on: note),
              case .configureNew(let left) = try commands.perform(.insertLeft, on: note) else {
            Issue.record("вставка не открыла окно новой колонки")
            return
        }
        #expect(try names() == ["Название", "Свойство 1", "Заметка", "Свойство"])
        #expect(try store.write { [try $0.property(right)?.name, try $0.property(left)?.name] } == ["Свойство", "Свойство 1"])
        #expect(try columns().count == 4)
        #expect(try commands.perform(.editProperty, on: note) == .openEditPanel)
        #expect(try commands.perform(.changeType, on: note) == .openTypeList)
        #expect(try commands.perform(.delete, on: note) == .confirmDelete)
        #expect(try names().count == 4)
    }

    @Test("Дублировать — копия «Имя (1)» справа")
    func duplicate() throws {
        let note = try operations.addProperty(to: base.databaseId, name: "Заметка", kind: .text)
        _ = try commands.perform(.duplicate, on: note)
        #expect(try names() == ["Название", "Заметка", "Заметка (1)"])
    }

    @Test("Удаление после подтверждения — в «Удалённые свойства»; текст вопроса с именем базы")
    func deleteConfirmed() throws {
        let note = try operations.addProperty(to: base.databaseId, name: "Заметка", kind: .text)
        #expect(try commands.deleteQuestion() == "Удалить это свойство из «Задачи»? Оно пропадёт из всех видов.")
        try commands.delete(note)
        #expect(try names() == ["Название"])
        #expect(try DatabaseCatalog.deletedProperties(of: base.databaseId, in: store).map(\.name) == ["Заметка"])
    }

    @Test("Переименование: пробелы обрезаются; пустое и прежнее имя ничего не пишут")
    func rename() throws {
        let note = try operations.addProperty(to: base.databaseId, name: "Заметка", kind: .text)
        #expect(try commands.rename(note, to: "  Описание ") == true)
        #expect(try names() == ["Название", "Описание"])
        let renamed = try property("Описание")
        #expect(try commands.rename(renamed, to: "   ") == false)
        #expect(try commands.rename(renamed, to: "Описание") == false)
    }

    @Test("Сменить тип: тот же тип ничего не делает, другой — меняет")
    func changeType() throws {
        let note = try operations.addProperty(to: base.databaseId, name: "Заметка", kind: .text)
        #expect(try commands.changeType(note, to: .text) == false)
        #expect(try commands.changeType(note, to: .number) == true)
        #expect(try property("Заметка").kind == .number)
    }

    @Test("Новое свойство из «+»: имя из поля, пустое — по типу без повторов; колонка в конце вида")
    func addNew() throws {
        let first = try commands.addProperty(named: "  ", kind: .number)
        let second = try commands.addProperty(named: "", kind: .number)
        let named = try commands.addProperty(named: " Срок ", kind: .date)
        #expect([first.name, second.name, named.name] == ["Число", "Число 1", "Срок"])
        #expect(try columns().last == named.id)
    }

    // MARK: Список типов

    @Test("Список типов для «Сменить тип»: текущий отмечен; «Название» в списке нет; ID серый, если уже есть")
    func typeRows() throws {
        _ = try operations.addProperty(to: base.databaseId, name: "№", kind: .uniqueId)
        let note = try operations.addProperty(to: base.databaseId, name: "Заметка", kind: .text)
        let rows = try commands.typeRows(current: note)
        let all = rows.flatMap { $0 }
        #expect(!all.contains { $0.kind == .title })
        #expect(all.first { $0.kind == .uniqueId }?.isEnabled == false)
        #expect(all.first { $0.kind == .text }?.isEnabled == true)
    }

    @Test("Клавиши списка типов: ↓ — та же колонка ниже, → — соседняя, серый ID пропускается, края не прокручиваются")
    func typeGridNavigation() {
        let rows = PropertyTypePicker.rows(existingKinds: [.uniqueId])
        let move = { (kind: PropertyKind?, direction: PropertyTypePicker.Direction) in PropertyTypePicker.move(from: kind, direction, in: rows) }
        #expect(move(nil, .down) == .text)
        #expect(move(.text, .right) == .number)
        #expect(move(.number, .down) == .multiSelect)
        #expect(move(.text, .down) == .select)
        #expect(move(.phone, .down) == .email)
        #expect(move(.email, .down) == .relation)
        #expect(move(.rollup, .down) == .formula)
        #expect(move(.formula, .right) == .formula)
        #expect(move(.formula, .down) == .createdTime)
        #expect(move(.lastEditedTime, .down) == .lastEditedTime)
        #expect(move(.text, .up) == .text)
        #expect(move(.relation, .up) == .email)
        let found = PropertyTypePicker.rows(existingKinds: [], matching: "ссыл")
        #expect(PropertyTypePicker.move(from: nil, .down, in: found) == .url)
    }

    // MARK: Клавиши меню

    @Test("Стрелки меню: черты пропускаются, по кругу; первая ↓ — первый пункт, ↑ — последний")
    func menuHighlight() {
        let selectable = [true, true, false, true]
        #expect(MenuHighlight.move(from: nil, by: 1, selectable: selectable) == 0)
        #expect(MenuHighlight.move(from: nil, by: -1, selectable: selectable) == 3)
        #expect(MenuHighlight.move(from: 1, by: 1, selectable: selectable) == 3)
        #expect(MenuHighlight.move(from: 3, by: 1, selectable: selectable) == 0)
        #expect(MenuHighlight.move(from: 0, by: -1, selectable: selectable) == 3)
        #expect(MenuHighlight.move(from: nil, by: 1, selectable: [false]) == nil)
    }

    // MARK: Окно «Свойства»

    @Test("Окно «Свойства»: свойства по порядку; перестановка по месту вставки; удалённые с «Вернуть» и «Удалить навсегда»")
    func propertiesWindow() throws {
        let a = try operations.addProperty(to: base.databaseId, name: "А", kind: .text)
        _ = try operations.addProperty(to: base.databaseId, name: "Б", kind: .text)
        let c = try operations.addProperty(to: base.databaseId, name: "В", kind: .text)
        var list = try PropertiesList.read(databaseId: base.databaseId, store: store)
        #expect(list.active.map(\.name) == ["Название", "А", "Б", "В"])
        // «А» (место 1) брошено перед «В» (место вставки 3) — встаёт после «Б».
        try list.move(a.id, toInsertionIndex: 3, operations: operations)
        #expect(try names() == ["Название", "Б", "А", "В"])
        try list.move(c.id, toInsertionIndex: 1, operations: operations)
        #expect(try names() == ["Название", "В", "Б", "А"])

        try commands.delete(try property("Б"))
        list = try PropertiesList.read(databaseId: base.databaseId, store: store)
        #expect(list.deleted.map(\.name) == ["Б"])
        try list.restore(list.deleted[0], operations: operations)
        #expect(try names() == ["Название", "В", "Б", "А"])

        try commands.delete(try property("Б"))
        list = try PropertiesList.read(databaseId: base.databaseId, store: store)
        try list.erase(list.deleted[0], operations: operations)
        list = try PropertiesList.read(databaseId: base.databaseId, store: store)
        #expect(list.deleted.isEmpty)
    }

    @Test("Удалённое ID не возвращается, пока в базе есть другое ID")
    func restoreUniqueId() throws {
        let first = try operations.addProperty(to: base.databaseId, name: "№", kind: .uniqueId)
        try operations.setDeleted(first.id, true)
        var list = try PropertiesList.read(databaseId: base.databaseId, store: store)
        #expect(list.canRestore(list.deleted[0]))
        _ = try operations.addProperty(to: base.databaseId, name: "№ 2", kind: .uniqueId)
        list = try PropertiesList.read(databaseId: base.databaseId, store: store)
        #expect(!list.canRestore(list.deleted[0]))
    }

    // MARK: Панель «Изменить свойство»

    @Test("Разделы панели US1: имя, тип, настройки типа (если есть окно), дублировать, удалить; у «Названия» — только имя")
    func panelSections() {
        #expect(PropertySettingsPanel.sections(for: .text, handled: PropertyMenuCommands.panelSlots).map(\.slot) == [.name, .type, .duplicate, .delete])
        #expect(PropertySettingsPanel.sections(for: .title, handled: PropertyMenuCommands.panelSlots).map(\.slot) == [.name])
        #expect(PropertySettingsPanel.sections(for: .number, handled: PropertyMenuCommands.panelSlots.union([.typeSettings])).map(\.slot)
                == [.name, .type, .typeSettings, .duplicate, .delete])
    }
}
