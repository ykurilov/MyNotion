import AppKit
import DatabaseGrid
import Databases
import Formulas
import NotesCore
import UIGallery
import VisualStyle

/// Формулы в галерее (US5, T055): редактор «Изменить формулу» в четырёх состояниях поверх открытой страницы «Задачи»
/// (эталон, 300 строк) и ячейки формул всех типов итога в своей базе «Формулы» — обе открываются настоящим переходом.
/// Сверка — `notion-formula-editor*.png`.
@MainActor
enum GalleryFormulasScene {
    private static var presenter: FormulaEditorPresenter?

    static func handles(_ kind: GalleryDatabases) -> Bool {
        [.formulaEditorEmpty, .formulaEditorResult, .formulaEditorError, .formulaEditorCycle, .formulaCells].contains(kind)
    }

    /// Сцена формул; итог — текст сбоя или `nil`.
    static func show(_ kind: GalleryDatabases, model: MainWindowModel, window: NSWindow) async -> String? {
        do {
            if kind == .formulaCells {
                try openCells(model: model)
                await settle()
                window.makeFirstResponder(nil)
            } else {
                try await openEditor(kind, model: model, window: window)
            }
        } catch {
            return "формулы не открылись: \(error)"
        }
        return nil
    }

    static func tearDown() {
        presenter?.close()
        presenter = nil
    }

    private static func settle() async { try? await Task.sleep(for: .milliseconds(500)) }

    private static func openEditor(_ kind: GalleryDatabases, model: MainWindowModel, window: NSWindow) async throws {
        let store = model.store
        let sample = try DatabaseSampleGenerator(taskCount: 300, projectCount: 20).ensure(in: store)
        let operations = DatabaseOperations(store: store)
        let property: DatabaseProperty
        var text = ""
        switch kind {
        case .formulaEditorCycle:
            // «Сумма» = prop("Итог"); правим «Итог» на prop("Сумма") — круг.
            let sum = try operations.addProperty(to: sample.tasksId, name: "Сумма", kind: .formula)
            try operations.setFormula(sum.id, display: #"prop("Итог")"#)
            property = try store.write { tx in try tx.property(sample.taskProperties["Итог"]!)! }
            text = #"prop("Сумма") + "!""#
        default:
            property = try operations.addProperty(to: sample.tasksId, name: "Формула", kind: .formula)
            text = switch kind {
            case .formulaEditorResult: #""Привет, " + prop("Название")"#
            case .formulaEditorError: #"dateBetween("2026-10-21", now(), "days")"#
            default: ""
            }
        }
        model.library.reloadTree()
        model.select(sample.tasksId)
        await settle()
        guard let anchor = window.contentView else { return }
        let rows = try ViewQuery.open(sample.tableViewId, in: store)?.result.rowIds ?? []
        let presenter = FormulaEditorPresenter()
        let editor = try presenter.show(property: property, rows: rows, operations: operations, besides: anchor)
        self.presenter = presenter
        if !text.isEmpty { editor.type(text) }
        await settle()
    }

    /// База «Формулы»: значения четырёх типов и формулы всех типов итога, по 6 строк.
    private static func openCells(model: MainWindowModel) throws {
        let store = model.store
        let operations = DatabaseOperations(store: store)
        let created = try operations.createDatabase(in: nil, isInline: false, title: "Формулы")
        let number = try operations.addProperty(to: created.databaseId, name: "Часы", kind: .number)
        let done = try operations.addProperty(to: created.databaseId, name: "Сделано", kind: .checkbox)
        let due = try operations.addProperty(to: created.databaseId, name: "Срок", kind: .date, config: ["dateFormat": "full"])
        let tags = try operations.addProperty(to: created.databaseId, name: "Метки", kind: .text)
        let formulas: [(String, String, JSONValue)] = [
            ("Часы × 2", #"prop("Часы") * 2"#, ["numberFormat": ["format": "number", "decimals": 1]]),
            ("Метка", #"if(prop("Сделано"), "✅ готово", "⏳ в работе")"#, .emptyObject),
            ("Не сделано", #"not prop("Сделано")"#, .emptyObject),
            ("Срок + неделя", #"dateAdd(prop("Срок"), 1, "weeks")"#, ["dateFormat": "full"]),
            ("Метки списком", #"split(prop("Метки"), ", ")"#, .emptyObject),
        ]
        var formulaIds: [UUID] = []
        for (name, text, config) in formulas {
            let property = try operations.addProperty(to: created.databaseId, name: name, kind: .formula, config: config)
            try operations.setFormula(property.id, display: text)
            formulaIds.append(property.id)
        }
        let rows: [(String, Double, Bool, String, String)] = [
            ("Купить молоко", 1, true, "2026-10-21", "дом, срочно"), ("Отчёт за квартал", 6.5, false, "2026-10-24", "работа"),
            ("Позвонить в банк", 0.5, false, "2026-10-22", "дела, звонок"), ("Ремонт велосипеда", 3, true, "2026-11-02", "дом"),
            ("Статья для клуба", 4, false, "2026-10-30", "работа, текст, клуб"), ("Запись к врачу", 0.25, true, "2026-10-23", "здоровье"),
        ]
        try store.write { tx throws in
            for (title, hours, isDone, date, labels) in rows {
                let page = try tx.createPage(title: title, parentId: created.databaseId)
                _ = try tx.setCell(rowId: page.id, propertyId: number.id, value: .number(hours))
                _ = try tx.setCell(rowId: page.id, propertyId: done.id, value: .bool(isDone))
                _ = try tx.setCell(rowId: page.id, propertyId: due.id, value: ["start": .string(date), "hasTime": false])
                _ = try tx.setCell(rowId: page.id, propertyId: tags.id, value: .string(labels))
            }
        }
        _ = try FormulaRecompute(store: store, databaseId: created.databaseId).recomputeAll()
        for id in [number.id, done.id] + formulaIds { try operations.setColumnWidth(id, in: created.viewId, to: 130) }
        try operations.setColumnWidth(due.id, in: created.viewId, to: 170)
        try operations.setColumnWidth(tags.id, in: created.viewId, to: 150)
        model.library.reloadTree()
        model.select(created.databaseId)
    }
}
