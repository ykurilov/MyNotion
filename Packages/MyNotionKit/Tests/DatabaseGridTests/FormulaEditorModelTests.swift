import AppKit
import Foundation
import Testing
@testable import DatabaseGrid
@testable import Databases
@testable import Formulas
@testable import NotesCore

/// Редактор формулы (contracts/formulas.md, «Редактор»): проверка текста, итог строки-примера, «Тип: …», ошибки и круг
/// блокируют «Готово», поиск по списку, вставка пункта, плашки свойств и запись с id.
@MainActor
@Suite("Редактор формулы")
struct FormulaEditorModelTests {
    let folder: URL
    let store: NotesStore
    let sample: DatabaseSampleGenerator.Sample
    let rows: [UUID]

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("formula-editor-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = NotesStore(database: try AppDatabase.open(at: folder.appendingPathComponent("MyNotion.sqlite")), clock: HybridLogicalClock(deviceId: UUID()))
        sample = try DatabaseSampleGenerator(taskCount: 40, projectCount: 5).ensure(in: store)
        rows = try ViewQuery.open(sample.tableViewId, in: store)!.result.rowIds
    }

    func property(_ name: String) throws -> DatabaseProperty {
        try store.write { tx in try tx.property(sample.taskProperties[name]!)! }
    }

    func model(_ name: String = "Итог") throws -> FormulaEditorModel {
        try FormulaEditorModel(store: store, property: try property(name), rows: rows)
    }

    @Test("Открытие: текст с названиями, тип и итог первой строки")
    func opens() throws {
        let editor = try model()
        #expect(editor.text == #"if(prop("Сделано"), "Готово", "В работе")"#)
        #expect(editor.typeLabel == "Тип: текст")
        let done = try store.write { tx in try tx.cell(rowId: rows[0], propertyId: sample.taskProperties["Сделано"]!)?.value?.bool ?? false }
        #expect(editor.outputText == (done ? "Готово" : "В работе"))
        #expect(editor.canSave && !editor.isChanged)
        #expect(editor.previewRow?.id == rows[0])
    }

    @Test("Ошибка разбора и круг — «Готово» неактивно, текст ошибки с местом")
    func errorsBlockSave() throws {
        let editor = try model()
        editor.edit("if(true, 1", caret: 10)
        #expect(!editor.canSave)
        #expect(editor.error == FormulaError("Ожидалась „)“", at: 10..<10))
        editor.edit(#"prop("Итог") + "!""#, caret: 3)
        #expect(!editor.canSave)
        #expect(editor.error?.message == "Формула ссылается сама на себя: Итог → Итог")
        editor.edit(#"dateBetween("2026", now(), "days")"#, caret: 0)
        #expect(editor.error?.message == "Функция dateBetween ждёт дату, а получила текст")
        #expect(!editor.canSave)
        editor.edit("", caret: 0)
        #expect(editor.canSave && editor.typeLabel == "Тип: неизвестно" && editor.outputText == "Нет итога")
    }

    @Test("Ошибка вычисления у строки-примера — текст ошибки, сохранять можно")
    func rowErrorShownButSavable() throws {
        let editor = try model()
        editor.edit("at([1], 3)", caret: 0)
        #expect(editor.canSave)
        #expect(editor.error?.message == "Номер 3 за пределами списка из 1")
    }

    @Test("Поиск по слову перед кареткой, описание с примерами, вставка функции и свойства")
    func listAndInsert() throws {
        let editor = try model()
        editor.edit("date", caret: 4)
        #expect(editor.sections.map(\.title) == ["Даты"])
        #expect(editor.sections[0].items.first == .function("date"))
        #expect(editor.sections[0].items.contains(.function("dateBetween")))
        let description = editor.description(of: .function("dateBetween"))
        #expect(description.title == "dateBetween(дата, дата, единица)" && !description.examples.isEmpty)
        let inserted = editor.inserting(.function("dateBetween"))
        #expect(inserted.text == "dateBetween()" && inserted.caret == 12)
        #expect(editor.inserting(.function("now")).caret == 5, "без аргументов — каретка после скобок")
        editor.edit("Сро", caret: 3)
        let deadline = try #require(editor.sections.first { $0.title == "Свойства" }?.items.first)
        #expect(deadline.title.hasPrefix("Срок"))
        #expect(editor.inserting(deadline).text.hasPrefix(#"prop("Срок"#))
        editor.edit("", caret: 0)
        #expect(editor.sections.map(\.title) == ["Свойства", "Встроенные", "Логика", "Числа", "Текст", "Даты", "Списки", "Страницы"])
        #expect(!(editor.sections[0].items.contains { $0.title == "Итог" }), "сама себя в списке не показывает")
    }

    @Test("Плашки: своё свойство и свойство строки из связи")
    func chips() throws {
        let editor = try model()
        editor.edit(#"prop("Проект").map(current.prop("Название")).join(", ")"#, caret: 0)
        let chips = editor.propertyChips
        #expect(chips.map(\.property.name) == ["Проект", "Название"])
        #expect(chips[1].property.id == sample.projectProperties["Название"]!.databaseText)
        #expect(chips[0].kind == .relation)
    }

    @Test("Другая строка предпросмотра — другой итог")
    func previewRow() throws {
        let editor = try model()
        editor.edit(#"prop("Название")"#, caret: 0)
        let titles = try store.write { tx in try rows.prefix(2).map { try tx.page($0)!.title } }
        #expect(editor.outputText == titles[0])
        editor.previewRow = editor.previewRows[1]
        #expect(editor.outputText == titles[1])
    }

    @Test("«Готово» пишет текст с id; вид: плашки в поле, текст формулы — с названиями")
    func saveAndView() throws {
        let editor = try model()
        let view = FormulaEditorView(model: editor, operations: DatabaseOperations(store: store))
        view.field.string = #"if(prop("Важно"), prop("Часы") * 2, 0)"#
        view.textDidChange(Notification(name: NSText.didChangeNotification))
        let storage = try #require(view.field.textStorage)
        var chips = 0
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in if value is FormulaChipAttachment { chips += 1 } }
        #expect(chips == 2)
        #expect(FormulaFieldText(storage).text == #"if(prop("Важно"), prop("Часы") * 2, 0)"#)
        #expect(view.doneButton.isEnabled)
        #expect(view.typeLabel.stringValue == "Тип: число")
        view.done()
        let stored = try property("Итог").config["expression"]?.string
        #expect(stored == #"if(prop("\#(sample.taskProperties["Важно"]!.databaseText)"), prop("\#(sample.taskProperties["Часы"]!.databaseText)") * 2, 0)"#)
        view.field.string = "1 +"
        view.textDidChange(Notification(name: NSText.didChangeNotification))
        #expect(!view.doneButton.isEnabled)
        #expect(view.outputLabel.stringValue == "Формула оборвалась: ожидалось значение")
    }
}
