import AppKit
import Foundation
import Testing
@testable import Databases
@testable import DatabaseGrid
@testable import NotesCore

/// Окна свойства без показа на экране (T039): пункты меню колонки и клавиши, список типов, «Свойства» базы.
@MainActor
@Suite("Окна свойства: виды (US1)")
struct PropertyMenuViewsTests {
    let store: NotesStore
    let operations: DatabaseOperations
    let base: CreatedDatabase
    let commands: PropertyMenuCommands

    init() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("propviews-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = NotesStore(database: try AppDatabase.open(at: folder.appendingPathComponent("MyNotion.sqlite")), clock: HybridLogicalClock(deviceId: UUID()))
        operations = DatabaseOperations(store: store)
        base = try operations.createDatabase(in: nil, isInline: false, title: "Задачи")
        commands = PropertyMenuCommands(store: store, operations: operations, databaseId: base.databaseId, viewId: base.viewId)
    }

    @Test("Меню колонки: имя в поле, пункты с чертой; ↓↓ и Enter выбирают второй пункт")
    func columnMenuKeyboard() throws {
        let note = try operations.addProperty(to: base.databaseId, name: "Заметка", kind: .text)
        var chosen: [PropertyMenuSlot] = []
        let menu = ColumnMenuView(property: note, entries: commands.entries(for: note)) { slot, _ in chosen.append(slot) }
        #expect(menu.nameField.text == "Заметка")
        #expect(menu.actions.outline == ["Изменить свойство", "Сменить тип", "—", "Вставить слева", "Вставить справа", "Дублировать свойство", "Удалить свойство"])
        _ = menu.nameField.onCommand?(#selector(NSResponder.moveDown(_:)))
        _ = menu.nameField.onCommand?(#selector(NSResponder.moveDown(_:)))
        _ = menu.nameField.onCommand?(#selector(NSResponder.insertNewline(_:)))
        #expect(chosen == [.changeType])
        var dismissed = false
        menu.onDismiss = { dismissed = true }
        _ = menu.nameField.onCommand?(#selector(NSResponder.moveUp(_:)))
        _ = menu.nameField.onCommand?(#selector(NSResponder.cancelOperation(_:)))
        #expect(dismissed)
    }

    @Test("Список типов: две колонки и поиск; Enter выбирает найденное; одна колонка — те же типы по одному")
    func typeList() throws {
        var chosen: PropertyKind?
        let list = PropertyTypeListView(columns: 2, current: .text) { query in (try? commands.typeRows(matching: query)) ?? [] }
        list.onChoose = { chosen = $0 }
        #expect(list.visibleTitles.prefix(4) == ["Текст", "Число", "Выбор", "Множественный выбор"])
        list.filter("флаж")
        #expect(list.visibleTitles == ["Флажок"])
        #expect(list.handle(#selector(NSResponder.insertNewline(_:))))
        #expect(chosen == .checkbox)
        let single = PropertyTypeListView(columns: 1, current: nil) { query in (try? commands.typeRows(matching: query)) ?? [] }
        #expect(single.visibleTitles.count == 17)
        #expect(single.contentHeight > list.contentHeight)
    }

    @Test("Числовая сводка переиспользует панель числа: вложенные настройки сохраняют связь и вычисление")
    func rollupNumberSettings() throws {
        let property = try operations.addProperty(to: base.databaseId, name: "Часов", kind: .rollup,
                                                  config: ["calculation": "sum", "relationPropertyId": "relation", "targetPropertyId": "hours"])
        let context = PropertyTypeSettingsContext(property: property, store: store, operations: operations, viewId: base.viewId)
        let number = NumberSettingsView(context: context, configKey: "numberFormat", showsNote: false)
        let undo = UndoManager()
        undo.groupsByEvent = false
        operations.undoManager = undo
        undo.beginUndoGrouping()
        number.updateConfig { $0["decimals"] = 2 }
        undo.endUndoGrouping()
        undo.beginUndoGrouping()
        number.updateConfig { $0["showAs"] = NumberDisplay.showAs(.ring, keeping: $0) }
        undo.endUndoGrouping()
        undo.undo()
        #expect(try store.write { try $0.property(property.id)?.config["numberFormat"]?["showAs"] } == nil)
        undo.redo()
        operations.undoManager = nil
        let config = try #require(try store.write { try $0.property(property.id)?.config })
        #expect(config["calculation"] == "sum" && config["relationPropertyId"] == "relation" && config["targetPropertyId"] == "hours")
        #expect(config["numberFormat"]?["decimals"] == 2)
        #expect(config["numberFormat"]?["showAs"]?["style"] == "ring")
        #expect(config["showAs"] == nil && config["decimals"] == nil)
        let current = try #require(try store.write { try $0.property(property.id) })
        let rollup = RollupSettingsView(context: PropertyTypeSettingsContext(property: current, store: store, operations: operations, viewId: base.viewId))
        let compact = rollup.fittingSize.height
        var resized = false
        rollup.onHeightChange = { resized = true }
        var fresh = config
        fresh["numberFormat"]?["showAs"] = nil
        try operations.setPropertyConfig(property.id, fresh)
        rollup.refresh()
        #expect(resized && rollup.fittingSize.height < compact)
        #expect(RollupSettingsView.hasNumberResult(.sum) && RollupSettingsView.hasNumberResult(.percentChecked))
        #expect(!RollupSettingsView.hasNumberResult(.showOriginal) && !RollupSettingsView.hasNumberResult(.dateRange))
    }

    @Test("Окно «Свойства»: «Новое свойство» и «Удалённые свойства» появляются после удаления")
    func propertiesWindow() throws {
        let note = try operations.addProperty(to: base.databaseId, name: "Заметка", kind: .text)
        let window = PropertiesWindowView(commands: commands)
        let before = window.contentHeight
        try commands.delete(note)
        window.reload()
        #expect(window.contentHeight > before)
    }
}
