import AppKit
import Databases
import NotesCore

/// `--relations-demo` (US4, T089): базы «Проекты» (Дом, Работа) и «Задачи» (Позвонить 2 ч, Купить 3 ч, Сдать отчёт 4 ч)
/// без связей; открыты «Задачи». `linked` — сразу связь «Проект» ↔ «Задачи» и сводка «Часов» (сумма часов) у «Проектов».
/// Повторный запуск на той же базе ничего не добавляет.
@MainActor
enum RelationsDemo {
    static func editorReady(model: MainWindowModel, linked: Bool) {
        do {
            let existing = try model.store.write { tx in
                try tx.fetchTexts(sql: "SELECT p.id FROM page p JOIN db_database d ON d.pageId = p.id WHERE p.title = 'Задачи' AND p.trashedAt IS NULL")
            }.first.flatMap(UUID.init(uuidString:))
            let tasks = try existing ?? makeDatabases(model.store, linked: linked)
            model.library.reloadTree()
            model.select(tasks)
        } catch {
            FileHandle.standardError.write(Data("Связи: база не записалась: \(error)\n".utf8))
        }
    }

    private static func makeDatabases(_ store: NotesStore, linked: Bool) throws -> UUID {
        let operations = DatabaseOperations(store: store)
        let projects = try operations.createDatabase(in: nil, isInline: false, title: "Проекты")
        for title in ["Дом", "Работа"] { try operations.addRow(to: projects.databaseId, in: projects.viewId, title: title) }
        let tasks = try operations.createDatabase(in: nil, isInline: false, title: "Задачи")
        let hours = try operations.addProperty(to: tasks.databaseId, name: "Часы", kind: .number)
        var taskRows: [UUID] = []
        for (title, value) in [("Позвонить", 2.0), ("Купить", 3.0), ("Сдать отчёт", 4.0)] {
            let row = try operations.addRow(to: tasks.databaseId, in: tasks.viewId, title: title)
            try operations.setCell(rowId: row, propertyId: hours.id, value: .number(value))
            taskRows.append(row)
        }
        guard linked else { return tasks.databaseId }
        let relation = try operations.addRelation(to: tasks.databaseId, name: "Проект", target: projects.databaseId, relatedName: "Задачи")
        let projectRows = try ViewQuery.open(projects.viewId, in: store)?.result.rowIds ?? []
        for (task, project) in zip(taskRows, [0, 0, 1]) where project < projectRows.count {
            try operations.linkRow(task, through: relation.id, to: projectRows[project])
        }
        let rollup = try operations.addProperty(to: projects.databaseId, name: "Часов", kind: .rollup)
        try operations.setRollup(rollup.id, relation: relation.pairedRelation, target: hours.id, calculation: .sum)
        return tasks.databaseId
    }
}
