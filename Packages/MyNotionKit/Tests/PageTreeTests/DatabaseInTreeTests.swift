import AppKit
import Foundation
import NotesCore
import Testing
@testable import PageTree

/// Базы в дереве панели (T017, research R1): строки базы и встроенные базы не показываются; полностраничная база —
/// значок таблицы, без стрелки; в корзину и обратно база уходит со строками.
@MainActor
@Suite("Базы в дереве")
struct DatabaseInTreeTests {
    static func page(_ title: String, parent: UUID? = nil, key: String) -> Page {
        Page(title: title, parentId: parent, sortKey: FractionalSortKey(rawValue: key)!, createdAt: .now, updatedAt: .now)
    }

    let host = Self.page("Обзор", key: "a")
    let tasks = Self.page("Задачи", key: "b")
    let row: Page
    let rowChild: Page
    let inline: Page

    init() {
        row = Self.page("Позвонить", parent: tasks.id, key: "a")
        rowChild = Self.page("Подстраница строки", parent: row.id, key: "a")
        inline = Self.page("Встроенная", parent: host.id, key: "b")
    }

    var snapshot: PageTreeSnapshot {
        PageTreeSnapshot(allPages: [host, tasks, row, rowChild, inline], databases: [tasks.id: false, inline.id: true])
    }

    @Test("Дети базы и встроенные базы в дереве не видны; сами страницы находятся по id")
    func hidesRowsAndInlineDatabases() {
        #expect(snapshot.children(of: nil).map(\.title) == ["Обзор", "Задачи"])
        #expect(snapshot.children(of: tasks.id).isEmpty)
        #expect(snapshot.children(of: host.id).isEmpty)
        #expect(snapshot.page(row.id)?.title == "Позвонить" && snapshot.page(inline.id) != nil)
        #expect(snapshot.ancestors(of: row.id).map(\.title) == ["Задачи"])
        #expect(snapshot.isDatabase(tasks.id) && snapshot.isDatabase(inline.id) && !snapshot.isDatabase(host.id))
        #expect(!snapshot.pagesInTreeOrder.contains { $0.id == row.id || $0.id == rowChild.id || $0.id == inline.id })
    }

    @Test("Полностраничная база в панели: без стрелки, значок таблицы")
    func databaseRowLooksLikeNotion() throws {
        let outline = PageOutlineView(frame: NSRect(x: 0, y: 0, width: 250, height: 300))
        let dataSource = PageOutlineDataSource(actions: PageTreeActions(select: { _ in }, rename: { _, _ in }, move: { _, _, _ in },
                                                                        moveToTrash: { _ in }, addSubpage: { _ in }, collapsedPagesChanged: { _ in }))
        dataSource.attach(to: outline)
        dataSource.show(snapshot, collapsedPageIds: [], selectedPageId: nil)
        #expect(outline.numberOfRows == 2)
        let item = try #require(outline.item(atRow: 1))
        #expect(!dataSource.outlineView(outline, isItemExpandable: item))
        let cell = try #require(dataSource.outlineView(outline, viewFor: nil, item: item) as? PageTreeCellView)
        #expect(cell.showsDatabaseGlyph)
        let firstItem = try #require(outline.item(atRow: 0))
        let pageCell = try #require(dataSource.outlineView(outline, viewFor: nil, item: firstItem) as? PageTreeCellView)
        #expect(!pageCell.showsDatabaseGlyph)
        withExtendedLifetime(dataSource) {}
    }

    @Test("Дерево из хранилища: строки и их подстраницы не читаются; база в корзину и обратно — со строками")
    func storeOutlineAndTrash() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tree-db-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = NotesStore(database: try AppDatabase.open(at: folder.appendingPathComponent("MyNotion.sqlite")), clock: HybridLogicalClock(deviceId: UUID()))
        let (database, rowId) = try store.write { tx in
            let database = try tx.createPage(title: "Задачи")
            try tx.saveDatabase(DatabaseSchema(pageId: database.id))
            let text = try tx.saveProperty(DatabaseProperty(databaseId: database.id, name: "Текст", kind: .text, sortKey: .between(nil, nil)))
            let row = try tx.createPage(title: "Строка", parentId: database.id)
            _ = try tx.createPage(title: "Под строкой", parentId: row.id)
            try tx.setCell(rowId: row.id, propertyId: text.id, value: ["runs": [], "string": "значение"])
            return (database.id, row.id)
        }
        let tree = try store.pageTree()
        #expect(tree.children(of: nil).map(\.title) == ["Задачи"])
        #expect(tree.page(rowId) == nil, "строки базы дерево не читает")
        #expect(tree.isDatabase(database))
        let operations = PageTreeOperations(store: store)
        try operations.moveToTrash(database)
        #expect(try store.pageTree().children(of: nil).isEmpty)
        #expect(try store.trashEntries().map(\.id) == [database])
        try operations.restore(database)
        #expect(try store.pageTree().children(of: nil).map(\.id) == [database])
        try store.write { tx throws in
            #expect(try tx.page(rowId)?.trashedAt == nil)
            #expect(try tx.cells(ofRow: rowId).first?.value?["string"] == "значение")
        }
    }
}
