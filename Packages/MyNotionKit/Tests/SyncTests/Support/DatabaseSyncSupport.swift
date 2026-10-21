import Foundation
import Testing
@testable import NotesCore
@testable import Sync

/// База «Задачи» для тестов синхронизации 004: название, текст, выбор (вариант «Готово»), связь на себя, вид, строка с
/// ячейками, связью и местом в виде.
struct SyncTasksDatabase {
    var database: UUID
    var title: UUID
    var text: UUID
    var select: UUID
    var relation: UUID
    var option: UUID
    var view: UUID
    var row: UUID
    var otherRow: UUID
}

@MainActor
func makeTasksDatabase(on mac: SyncTestMac) throws -> SyncTasksDatabase {
    try mac.store.write { tx in
        let page = try tx.createPage(title: "Задачи")
        try tx.saveDatabase(DatabaseSchema(pageId: page.id))
        var key: FractionalSortKey?
        func property(_ name: String, _ kind: PropertyKind, _ config: JSONValue = .emptyObject) throws -> UUID {
            key = .between(key, nil)
            return try tx.saveProperty(DatabaseProperty(databaseId: page.id, name: name, kind: kind, config: config, sortKey: key!)).id
        }
        let title = try property("Название", .title)
        let text = try property("Описание", .text)
        let select = try property("Статус", .select)
        let relation = try property("Связано", .relation, ["targetDatabaseId": .string(page.id.uuidString.lowercased()), "limit": "none"])
        let option = try tx.saveOption(SelectOption(propertyId: select, name: "Готово", color: .green, sortKey: .between(nil, nil))).id
        let view = try tx.saveView(DatabaseView(databaseId: page.id, sortKey: .between(nil, nil),
                                                layoutOptions: ["loadLimit": 50, "futureKey": "x"])).id
        let row = try tx.createPage(title: "Позвонить", parentId: page.id).id
        let other = try tx.createPage(title: "Купить", parentId: page.id).id
        try tx.setCell(rowId: row, propertyId: text, value: ["runs": [], "string": "в банк"])
        try tx.setCell(rowId: row, propertyId: select, value: .string(option.uuidString.lowercased()))
        try tx.saveRelationLink(RelationLink(propertyId: relation, rowId: row, targetRowId: other, sortKey: .between(nil, nil)))
        try tx.setRowOrder(viewId: view, rowId: other, sortKey: .between(nil, nil))
        return SyncTasksDatabase(database: page.id, title: title, text: text, select: select, relation: relation, option: option, view: view,
                                 row: row, otherRow: other)
    }
}

extension SyncTestMac {
    func cellText(_ db: SyncTasksDatabase, row: UUID? = nil, property: UUID? = nil) throws -> String? {
        try store.write { tx in try tx.cell(rowId: row ?? db.row, propertyId: property ?? db.text)?.value?["string"]?.string }
    }

    func dbProperty(_ id: UUID) throws -> DatabaseProperty? { try store.write { try $0.property(id) } }
}
