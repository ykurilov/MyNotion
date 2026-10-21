import Foundation
import GRDB
import Testing
@testable import NotesCore

/// Чтение дерева панели (research R1, T030): страницы от корней без строк баз и их подстраниц, корзина целиком,
/// сироты — в корне. Строк баз десятки тысяч: запрос идёт по индексам и таблицу страниц целиком не читает
/// (иначе первый запуск на холодном диске — плюс 1,3 с на эталоне 004).
@Suite("Дерево из хранилища")
struct TreeOutlineTests {
    let folder: TemporaryFolder
    let store: NotesStore

    init() throws {
        folder = try TemporaryFolder()
        store = try NotesStore(database: AppDatabase.open(at: folder.databaseURL), clock: HybridLogicalClock(deviceId: UUID()))
    }

    @Test("Видно: страницы, базы, корзина, сироты и их ветки; не видно: строки баз и то, что внутри строк")
    func readsPagesTrashAndOrphansWithoutDatabaseRows() throws {
        let ids = try store.write { tx throws in
            let home = try tx.createPage(title: "Дом")
            let nested = try tx.createPage(title: "Вложенная", parentId: home.id)
            let deep = try tx.createPage(title: "Глубокая", parentId: nested.id)
            let trashed = try tx.createPage(title: "В корзине", parentId: home.id)
            let underTrashed = try tx.createPage(title: "Под корзиной", parentId: trashed.id)
            var trashedPage = trashed
            trashedPage.trashedAt = Date()
            try tx.updatePage(trashedPage)

            let tasks = try tx.createPage(title: "Задачи")
            try tx.saveDatabase(DatabaseSchema(pageId: tasks.id))
            let row = try tx.createPage(title: "Строка", parentId: tasks.id)
            let rowChild = try tx.createPage(title: "Под строкой", parentId: row.id)
            var trashedRow = try tx.createPage(title: "Удалённая строка", parentId: tasks.id)
            trashedRow.trashedAt = Date()
            try tx.updatePage(trashedRow)

            let inline = try tx.createPage(title: "Встроенная", parentId: nested.id)
            try tx.saveDatabase(DatabaseSchema(pageId: inline.id, isInline: true))
            let inlineRow = try tx.createPage(title: "Строка встроенной", parentId: inline.id)

            let orphan = try tx.createPage(title: "Сирота", parentId: home.id)
            let orphanChild = try tx.createPage(title: "Под сиротой", parentId: orphan.id)
            return (shown: [home, nested, deep, trashed, underTrashed, tasks, trashedRow, inline, orphan, orphanChild].map(\.id),
                    hidden: [row, rowChild, inlineRow].map(\.id), tasks: tasks.id, inline: inline.id, orphan: orphan.id)
        }
        // Родитель исчез (стёрт на другом Mac, ещё не пришёл): страница показывается в корне.
        try store.database.dbWriter.write { db in
            try db.execute(sql: "UPDATE page SET parentId = ? WHERE id = ?", arguments: [UUID().databaseText, ids.orphan.databaseText])
        }

        let outline = try store.treeOutline()

        #expect(Set(outline.pages.map(\.id)) == Set(ids.shown))
        #expect(outline.pages.allSatisfy { !ids.hidden.contains($0.id) })
        #expect(outline.databases == [ids.tasks: false, ids.inline: true])
        let order = outline.pages.map { ($0.sortKey.rawValue, $0.id.databaseText) }
        #expect(order.elementsEqual(order.sorted { $0 < $1 }, by: ==), "порядок — sortKey, затем id")
        let tree = PageTreeSnapshot(allPages: outline.pages, databases: outline.databases)
        #expect(Set(tree.children(of: nil).map(\.title)) == ["Дом", "Задачи", "Сирота"])
    }

    @Test("Запрос дерева не читает таблицу страниц целиком: только поиск по индексам")
    func treeQueryUsesIndexesOnly() throws {
        let plan = try store.database.dbWriter.read { db in
            try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + NotesStore.treeOutlineSQL).map { $0["detail"] as String }
        }
        let fullScans = plan.filter { $0.hasPrefix("SCAN page") }
        #expect(fullScans.isEmpty, "полный проход по page: \(fullScans), план: \(plan)")
    }
}
