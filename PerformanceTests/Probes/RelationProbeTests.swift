import AppKit
import Databases
import NotesCore
import XCTest

/// Проба связей и сводок (T007, research R20.4): 10 000 задач ↔ 500 проектов. Правка часов задачи пересчитывает сводки
/// проекта («Число задач», «Сумма часов») в той же транзакции ≤ 10 мс; проект с 1 000 задач в корзину и обратно — с
/// пересчётом сводки «Срок проекта» у его задач — ≤ 200 мс; сводки совпадают с подсчётом «в лоб».
@MainActor
final class RelationProbeTests: XCTestCase {
    static let editBudgetMs = 10.0
    static let trashBudgetMs = 200.0
    static let bigProjectTasks = 1_000

    func testRollupsFollowEditsAndTrashWithinBudget() throws {
        let library = try DatabaseProbeLibrary.copy()
        defer { library.store.database.close(); try? FileManager.default.removeItem(at: library.folder) }
        let store = library.store, sample = library.sample
        let ids = RollupIds(sample: sample)
        let tasks = try XCTUnwrap(try ViewQuery.open(sample.tableViewId, in: store)).result.rowIds
        let projects = try store.write { tx in
            try tx.fetchTexts(sql: "SELECT id FROM page WHERE parentId = ? ORDER BY sortKey", arguments: [.text(ids.text(sample.projectsId))])
                .compactMap(UUID.init(uuidString:))
        }

        // Большой проект: первые 1 000 задач переносятся в проект 1 (подготовка, без замера), сводки — заново.
        let big = projects[0]
        try store.write { tx in
            for task in tasks.prefix(Self.bigProjectTasks) {
                for link in try tx.relationLinks(propertyId: ids.taskRelation, rowId: task) where link.targetRowId != big {
                    var removed = link
                    removed.isPresent = false
                    try tx.saveRelationLink(removed)
                }
                try tx.saveRelationLink(RelationLink(propertyId: ids.taskRelation, rowId: task, targetRowId: big, sortKey: .between(nil, nil)))
            }
            for project in projects { try Self.recomputeProjectRollups(project, ids: ids, in: tx) }
        }

        // Правка часов задачи — сводки её проекта в той же транзакции.
        var edits: [Double] = []
        for step in 0..<30 {
            let task = tasks[Self.bigProjectTasks + 10 + step]
            let ms = try ProbeEditor.measure {
                try store.write { tx in
                    let hours = try tx.cell(rowId: task, propertyId: ids.hours)?.value?.number ?? 0
                    try tx.setCell(rowId: task, propertyId: ids.hours, value: .number(hours + 0.5))
                    try tx.execute(sql: "UPDATE db_cell SET sortNumber = ? WHERE rowId = ? AND propertyId = ?",
                                   arguments: [.real(hours + 0.5), .text(ids.text(task)), .text(ids.text(ids.hours))])
                    for link in try tx.relationLinks(propertyId: ids.taskRelation, rowId: task) {
                        try Self.recomputeProjectRollups(link.targetRowId, ids: ids, in: tx)
                    }
                }
            }
            if step >= 5 { edits.append(ms) }
        }
        // Большой проект тоже: правка его задачи пересчитывает сумму по 1 000 задач.
        var bigEdits: [Double] = []
        for step in 0..<15 {
            let task = tasks[step]
            bigEdits.append(try ProbeEditor.measure {
                try store.write { tx in
                    try tx.setCell(rowId: task, propertyId: ids.hours, value: .number(Double(step)))
                    try tx.execute(sql: "UPDATE db_cell SET sortNumber = ? WHERE rowId = ? AND propertyId = ?",
                                   arguments: [.real(Double(step)), .text(ids.text(task)), .text(ids.text(ids.hours))])
                    try Self.recomputeProjectRollups(big, ids: ids, in: tx)
                }
            })
        }

        // Проект с 1 000 задач — в корзину и обратно: «Срок проекта» у задач пересчитывается той же правкой.
        let operations = PageTreeOperations(store: store)
        var trash: [Double] = [], restore: [Double] = [], trashRecompute: [Double] = []
        for _ in 0..<5 {
            trash.append(try ProbeEditor.measure {
                try operations.moveToTrash(big)
                trashRecompute.append(try ProbeEditor.measure { try store.write { tx in try Self.recomputeTaskRollups(of: big, ids: ids, in: tx) } })
            })
            let emptied = try store.write { tx in
                try tx.fetchTexts(sql: "SELECT count(*) FROM db_computed WHERE propertyId = ? AND value IS NULL AND rowId IN (SELECT rowId FROM db_relation_link WHERE targetRowId = ? AND isPresent = 1)",
                                  arguments: [.text(ids.text(ids.taskDeadlineRollup)), .text(ids.text(big))]).first
            }
            let linked = try store.write { tx in
                try tx.fetchTexts(sql: "SELECT count(*) FROM db_relation_link WHERE propertyId = ? AND targetRowId = ? AND isPresent = 1",
                                  arguments: [.text(ids.text(ids.taskRelation)), .text(ids.text(big))]).first
            }
            XCTAssertEqual(emptied, linked, "У задач проекта в корзине «Срок проекта» не пуст")
            restore.append(try ProbeEditor.measure {
                try operations.restore(big)
                try store.write { tx in try Self.recomputeTaskRollups(of: big, ids: ids, in: tx) }
            })
        }

        // Сводки всех проектов — как подсчёт «в лоб».
        var wrong: [String] = []
        try store.write { tx in
            var count: [UUID: Int] = [:], sum: [UUID: Double] = [:]
            for task in tasks {
                let hours = try tx.cell(rowId: task, propertyId: ids.hours)?.value?.number ?? 0
                for link in try tx.relationLinks(propertyId: ids.taskRelation, rowId: task) {
                    count[link.targetRowId, default: 0] += 1
                    sum[link.targetRowId, default: 0] += hours
                }
            }
            for project in projects {
                let stored = try tx.fetchTexts(sql: "SELECT ifnull(sortNumber, 0) FROM db_computed WHERE rowId = ? AND propertyId IN (?, ?) ORDER BY propertyId = ? DESC",
                                               arguments: [.text(ids.text(project)), .text(ids.text(ids.countRollup)), .text(ids.text(ids.sumRollup)),
                                                           .text(ids.text(ids.countRollup))]).compactMap(Double.init)
                if stored.count != 2 || stored[0] != Double(count[project] ?? 0) || abs(stored[1] - (sum[project] ?? 0)) > 0.001 {
                    wrong.append("\(project): \(stored) ≠ \(count[project] ?? 0), \(sum[project] ?? 0)")
                }
            }
        }

        let summary = """
            Проба связей: правка часов задачи со сводками проекта p95 \(ProbeEditor.format(ProbeEditor.p95(edits))) мс (предел 10); \
            у проекта на \(Self.bigProjectTasks) задач p95 \(ProbeEditor.format(ProbeEditor.p95(bigEdits))) мс
            Проба связей: проект на \(Self.bigProjectTasks) задач в корзину \(trash.map(ProbeEditor.format).joined(separator: " / ")) мс, \
            обратно \(restore.map(ProbeEditor.format).joined(separator: " / ")) мс (предел 200), из них пересчёт сводок задач \
            \(trashRecompute.map(ProbeEditor.format).joined(separator: " / ")) мс; сводок не сошлось с подсчётом «в лоб»: \(wrong.count) из \(projects.count)
            """
        print(summary)
        add(XCTAttachment(string: summary))
        XCTAssertLessThanOrEqual(ProbeEditor.p95(edits), Self.editBudgetMs, "Правка со сводкой: p95 больше 10 мс")
        XCTAssertLessThanOrEqual(trash.max() ?? .infinity, Self.trashBudgetMs, "Корзина проекта дольше 200 мс")
        XCTAssertLessThanOrEqual(restore.max() ?? .infinity, Self.trashBudgetMs, "Возврат проекта дольше 200 мс")
        XCTAssertTrue(wrong.isEmpty, "Сводки не сходятся: \(wrong.prefix(3))")
    }

    struct RollupIds {
        let taskRelation, hours, taskDeadlineRollup, countRollup, sumRollup, projectDeadline: UUID

        init(sample: DatabaseSampleGenerator.Sample) {
            taskRelation = sample.taskProperties["Проект"]!
            hours = sample.taskProperties["Часы"]!
            taskDeadlineRollup = sample.taskProperties["Срок проекта"]!
            countRollup = sample.projectProperties["Число задач"]!
            sumRollup = sample.projectProperties["Сумма часов"]!
            projectDeadline = sample.projectProperties["Срок"]!
        }

        func text(_ id: UUID) -> String { id.uuidString.lowercased() }
    }

    /// Сводки проекта по связанным задачам вне корзины — одним запросом по индексу цели.
    nonisolated static func recomputeProjectRollups(_ project: UUID, ids: RollupIds, in tx: NotesTransaction) throws {
        let line = try tx.fetchTexts(sql: """
            SELECT COUNT(*) || char(9) || TOTAL(c.sortNumber) FROM db_relation_link l JOIN page t ON t.id = l.rowId
            LEFT JOIN db_cell c ON c.rowId = l.rowId AND c.propertyId = ?
            WHERE l.propertyId = ? AND l.targetRowId = ? AND l.isPresent = 1 AND t.trashedAt IS NULL
            """, arguments: [.text(ids.text(ids.hours)), .text(ids.text(ids.taskRelation)), .text(ids.text(project))]).first ?? "0\t0"
        let parts = line.split(separator: "\t").compactMap { Double($0) }
        for (property, value) in [(ids.countRollup, parts.first ?? 0), (ids.sumRollup, parts.last ?? 0)] {
            try writeComputed(project, property, value: .number(value), number: value, in: tx)
        }
    }

    /// «Срок проекта» у задач проекта: самый ранний срок связанных проектов вне корзины.
    nonisolated static func recomputeTaskRollups(of project: UUID, ids: RollupIds, in tx: NotesTransaction) throws {
        // Одним запросом: задачи проекта, у каждой — самый ранний срок её проектов вне корзины (строка минимума — её значение).
        try tx.executeCached(sql: """
            WITH tasks AS (SELECT rowId FROM db_relation_link WHERE propertyId = ?3 AND targetRowId = ?4 AND isPresent = 1)
            INSERT INTO db_computed (rowId, propertyId, value, sortNumber)
            SELECT t.rowId, ?1, m.value, m.earliest FROM tasks t LEFT JOIN (
                SELECT l.rowId AS rowId, c.value AS value, MIN(c.sortNumber) AS earliest
                FROM db_relation_link l JOIN page p ON p.id = l.targetRowId AND p.trashedAt IS NULL
                JOIN db_cell c ON c.rowId = l.targetRowId AND c.propertyId = ?2
                WHERE l.propertyId = ?3 AND l.isPresent = 1 AND l.rowId IN tasks GROUP BY l.rowId
            ) m ON m.rowId = t.rowId
            WHERE true
            ON CONFLICT(rowId, propertyId) DO UPDATE SET value = excluded.value, sortNumber = excluded.sortNumber
            """, arguments: [.text(ids.text(ids.taskDeadlineRollup)), .text(ids.text(ids.projectDeadline)), .text(ids.text(ids.taskRelation)),
                             .text(ids.text(project))])
    }

    nonisolated static func writeComputed(_ row: UUID, _ property: UUID, value: JSONValue, number: Double, in tx: NotesTransaction) throws {
        try tx.executeCached(sql: """
            INSERT INTO db_computed (rowId, propertyId, value, sortNumber) VALUES (?, ?, ?, ?)
            ON CONFLICT(rowId, propertyId) DO UPDATE SET value = excluded.value, sortNumber = excluded.sortNumber
            """, arguments: [.text(row.uuidString.lowercased()), .text(property.uuidString.lowercased()), .text(value.jsonText), .real(number)])
    }
}
