import AppKit
import DatabaseGrid
import Databases
import NotesCore

/// `--formula-editor-demo` (US5, T050): малый эталон баз (300 задач), у «Задач» новое свойство «Формула» и открытый
/// редактор формулы поверх окна — для UI-сценария, пока панель «Изменить свойство» не пришла из US1.
/// «Готово» сохраняет формулу операцией окна и закрывает редактор; повторно открыть — пункт «Формула» снова.
@MainActor
enum FormulaEditorDemo {
    private static let presenter = FormulaEditorPresenter()

    static func editorReady(model: MainWindowModel) {
        guard let window = model.window, let anchor = window.contentView else { return }
        do {
            let sample = try DatabaseSampleGenerator(taskCount: 300, projectCount: 20).ensure(in: model.store)
            let operations = DatabaseOperations(store: model.store, undoManager: window.undoManager)
            let existing = try model.store.write { tx in
                try tx.properties(ofDatabase: sample.tasksId).first { $0.name == "Формула" && $0.kind == .formula }
            }
            let property = try existing ?? operations.addProperty(to: sample.tasksId, name: "Формула", kind: .formula)
            let rows = try ViewQuery.open(sample.tableViewId, in: model.store)?.result.rowIds ?? []
            try presenter.show(property: property, rows: rows, operations: operations, besides: anchor)
        } catch {
            FileHandle.standardError.write(Data("Редактор формулы: \(error)\n".utf8))
        }
    }
}
