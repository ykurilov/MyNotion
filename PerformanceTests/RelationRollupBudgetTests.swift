import AppKit
import Databases
import NotesCore
import XCTest

/// Замеры связей и сводок US4 (T094, research R8, проба R20.4) на эталоне баз (10 000 задач ↔ 500 проектов) с настоящим
/// подписчиком записи (`ComputationHook`): правка часов задачи пересчитывает сводки её проекта той же записью ≤ 10 мс p95;
/// связь задачи с другим проектом (обе сводки) ≤ 10 мс p95; проект с 1 000 задач в корзину и обратно — с пересчётом
/// «Срок проекта» и «Проект (имя)» у его задач — ≤ 200 мс; сводки всех проектов сходятся с подсчётом «в лоб».
@MainActor
final class RelationRollupBudgetTests: XCTestCase {
    static let editBudgetMs = 10.0
    static let trashBudgetMs = 200.0
    static let bigProjectTasks = 1_000

    func testRollupsThroughHookWithinBudget() throws {
        let library = try autoreleasepool { try DatabaseProbeLibrary.copy() }
        defer { library.store.database.close(); try? FileManager.default.removeItem(at: library.folder) }
        let store = library.store, sample = library.sample
        let queue = FormulaRecomputeQueue(store: store)
        store.addWriteHook(CellIndexer())
        store.addWriteHook(ComputationHook(store: store, queue: queue))
        let operations = DatabaseOperations(store: store)
        let relation = sample.taskProperties["Проект"]!, hours = sample.taskProperties["Часы"]!
        let count = sample.projectProperties["Число задач"]!, sum = sample.projectProperties["Сумма часов"]!
        let tasks = try XCTUnwrap(try ViewQuery.open(sample.tableViewId, in: store)).result.rowIds
        let projects = try store.write { tx in
            try tx.fetchTexts(sql: "SELECT id FROM page WHERE parentId = ? ORDER BY sortKey", arguments: [.text(sample.projectsId.uuidString.lowercased())])
                .compactMap(UUID.init(uuidString:))
        }

        // Большой проект: первые 1 000 задач переносятся в проект 1 (подготовка, без замера) одной записью.
        let big = projects[0]
        try store.write { tx in
            for task in tasks.prefix(Self.bigProjectTasks) {
                for link in try tx.relationLinks(propertyId: relation, rowId: task) where link.targetRowId != big {
                    var removed = link
                    removed.isPresent = false
                    try tx.saveRelationLink(removed)
                }
                try tx.saveRelationLink(RelationLink(propertyId: relation, rowId: task, targetRowId: big, sortKey: .between(nil, nil)))
            }
        }

        var edits: [Double] = [], relinks: [Double] = []
        for step in 0..<30 {
            let task = tasks[Self.bigProjectTasks + 10 + step]
            let value = Double(step % 7) + 0.5
            let ms = try ProbeEditor.measure { try operations.setCell(rowId: task, propertyId: hours, value: .number(value)) }
            if step >= 5 { edits.append(ms) }
            let other = projects[1 + (step % (projects.count - 1))]
            let relinkMs = try ProbeEditor.measure { try operations.linkRow(task, through: relation, to: other) }
            if step >= 5 { relinks.append(relinkMs) }
        }
        var bigEdits: [Double] = []
        for step in 0..<15 {
            bigEdits.append(try ProbeEditor.measure { try operations.setCell(rowId: tasks[step], propertyId: hours, value: .number(Double(step))) })
        }

        var trash: [Double] = [], restore: [Double] = []
        for _ in 0..<5 {
            trash.append(try ProbeEditor.measure { try operations.trashRows([big]) })
            restore.append(try ProbeEditor.measure { try operations.setRowsTrashed([big], false) })
        }
        queue.waitUntilIdle()

        // Сводки всех проектов — как подсчёт «в лоб» по живым связям.
        var wrong: [String] = []
        try store.write { tx in
            var counts: [UUID: Int] = [:], sums: [UUID: Double] = [:]
            for task in tasks {
                let value = try tx.cell(rowId: task, propertyId: hours)?.value?.number ?? 0
                for link in try tx.relationLinks(propertyId: relation, rowId: task) {
                    counts[link.targetRowId, default: 0] += 1
                    sums[link.targetRowId, default: 0] += value
                }
            }
            for project in projects {
                let stored = try [count, sum].map { property in
                    try tx.fetchTexts(sql: "SELECT ifnull(sortNumber, 0) FROM db_computed WHERE rowId = ? AND propertyId = ?",
                                      arguments: [.text(project.uuidString.lowercased()), .text(property.uuidString.lowercased())]).first.flatMap(Double.init) ?? 0
                }
                if stored[0] != Double(counts[project] ?? 0) || abs(stored[1] - (sums[project] ?? 0)) > 0.001 {
                    wrong.append("\(project): \(stored) ≠ \(counts[project] ?? 0), \(sums[project] ?? 0)")
                }
            }
        }

        let summary = """
            Связи US4: правка часов задачи со сводками проекта p95 \(ProbeEditor.format(ProbeEditor.p95(edits))) мс, \
            связь задачи с другим проектом p95 \(ProbeEditor.format(ProbeEditor.p95(relinks))) мс (предел 10); \
            у проекта на \(Self.bigProjectTasks) задач правка p95 \(ProbeEditor.format(ProbeEditor.p95(bigEdits))) мс
            Связи US4: проект на \(Self.bigProjectTasks) задач в корзину \(trash.map(ProbeEditor.format).joined(separator: " / ")) мс, \
            обратно \(restore.map(ProbeEditor.format).joined(separator: " / ")) мс (предел 200); \
            сводок не сошлось с подсчётом «в лоб»: \(wrong.count) из \(projects.count)
            """
        print(summary)
        add(XCTAttachment(string: summary))
        XCTAssertLessThanOrEqual(ProbeEditor.p95(edits), Self.editBudgetMs, "Правка со сводкой: p95 больше 10 мс")
        XCTAssertLessThanOrEqual(ProbeEditor.p95(relinks), Self.editBudgetMs, "Правка связи: p95 больше 10 мс")
        XCTAssertLessThanOrEqual(trash.max() ?? .infinity, Self.trashBudgetMs, "Корзина проекта дольше 200 мс")
        XCTAssertLessThanOrEqual(restore.max() ?? .infinity, Self.trashBudgetMs, "Возврат проекта дольше 200 мс")
        XCTAssertTrue(wrong.isEmpty, "Сводки не сходятся: \(wrong.prefix(3))")
    }
}
