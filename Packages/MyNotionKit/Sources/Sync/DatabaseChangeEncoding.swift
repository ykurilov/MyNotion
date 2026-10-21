import Foundation
import NotesCore

/// Записи баз в изменения полей пачки v4 и обратно (contracts/sync-v4-and-export.md, «Новые сущности»):
/// у каждого поля своя метка; `pageId` — страница-база; значения — JSON как в контракте.
enum DatabaseChangeEncoding {
    /// Изменения транзакции, сделанные этим Mac: правки с других Mac обратно не уходят.
    static func outgoing(_ changes: DatabaseChanges, in transaction: NotesTransaction) throws -> [SyncChange] {
        guard !changes.isEmpty else { return [] }
        let mine = transaction.clock.deviceId
        var result: [SyncChange] = []
        var databaseOfProperty: [UUID: UUID?] = [:]
        func database(ofProperty id: UUID) throws -> UUID? {
            if let known = databaseOfProperty[id] { return known }
            let found = try transaction.databaseId(ofProperty: id)
            databaseOfProperty[id] = found
            return found
        }
        for change in changes.databases {
            for field in DatabaseSchema.Field.allCases where change.changedFields.contains(field) {
                guard let stamp = change.record.fieldClocks[field], stamp.deviceId == mine else { continue }
                result.append(SyncChange(entity: .database, id: change.record.pageId, pageId: change.record.pageId,
                                         value: .databaseField(field.rawValue, value(of: change.record, field)), hlc: stamp))
            }
        }
        for change in changes.properties {
            for field in DatabaseProperty.Field.allCases where change.changedFields.contains(field) {
                guard let stamp = change.record.fieldClocks[field], stamp.deviceId == mine else { continue }
                result.append(SyncChange(entity: .property, id: change.record.id, pageId: change.record.databaseId,
                                         value: .databaseField(field.rawValue, value(of: change.record, field)), hlc: stamp))
            }
        }
        for change in changes.options {
            let databaseId = try database(ofProperty: change.record.propertyId)
            for field in SelectOption.Field.allCases where change.changedFields.contains(field) {
                guard let stamp = change.record.fieldClocks[field], stamp.deviceId == mine else { continue }
                result.append(SyncChange(entity: .option, id: change.record.id, pageId: databaseId,
                                         value: .databaseField(field.rawValue, value(of: change.record, field)), hlc: stamp))
            }
        }
        for change in changes.views {
            for field in DatabaseView.Field.allCases where change.changedFields.contains(field) {
                guard let stamp = change.record.fieldClocks[field], stamp.deviceId == mine else { continue }
                result.append(SyncChange(entity: .view, id: change.record.id, pageId: change.record.databaseId,
                                         value: .databaseField(field.rawValue, value(of: change.record, field)), hlc: stamp))
            }
        }
        for cell in changes.cells where cell.hlc.deviceId == mine {
            result.append(self.cell(cell, databaseId: try database(ofProperty: cell.propertyId)))
        }
        for change in changes.relationLinks {
            let databaseId = try database(ofProperty: change.record.propertyId)
            for field in RelationLink.Field.allCases where change.changedFields.contains(field) || (field == .link && change.isNew) {
                guard let stamp = change.record.fieldClocks[field], stamp.deviceId == mine else { continue }
                result.append(SyncChange(entity: .relationLink, id: change.record.id, pageId: databaseId,
                                         value: .databaseField(field.rawValue, value(of: change.record, field)), hlc: stamp))
            }
        }
        for order in changes.rowOrders where order.hlc.deviceId == mine {
            result.append(rowOrder(order, databaseId: try transaction.databaseId(ofView: order.viewId)))
        }
        return result
    }

    /// Все записи баз целиком: снимок для нового Mac и первая отправка (поле без метки — с самой ранней).
    static func fullRecords(in transaction: NotesTransaction) throws -> [SyncChange] {
        let records = try transaction.allDatabaseRecords()
        let propertyDatabase = Dictionary(uniqueKeysWithValues: records.properties.map { ($0.id, $0.databaseId) })
        let viewDatabase = Dictionary(uniqueKeysWithValues: records.views.map { ($0.id, $0.databaseId) })
        var result: [SyncChange] = []
        func fields<Record: ClockedDatabaseRecord>(_ record: Record, entity: SyncChange.Entity, id: UUID, pageId: UUID?,
                                                   value: (Record, Record.Field) -> JSONValue) -> [SyncChange] {
            Record.Field.allCases.map { field in
                SyncChange(entity: entity, id: id, pageId: pageId, value: .databaseField(field.rawValue, value(record, field)),
                           hlc: record.fieldClocks[field] ?? .distantPast)
            }
        }
        for schema in records.databases {
            result += fields(schema, entity: .database, id: schema.pageId, pageId: schema.pageId, value: value(of:_:))
        }
        for property in records.properties {
            result += fields(property, entity: .property, id: property.id, pageId: property.databaseId, value: value(of:_:))
        }
        for option in records.options {
            result += fields(option, entity: .option, id: option.id, pageId: propertyDatabase[option.propertyId], value: value(of:_:))
        }
        for view in records.views {
            result += fields(view, entity: .view, id: view.id, pageId: view.databaseId, value: value(of:_:))
        }
        result += records.cells.map { cell($0, databaseId: propertyDatabase[$0.propertyId]) }
        for link in records.links {
            result += fields(link, entity: .relationLink, id: link.id, pageId: propertyDatabase[link.propertyId], value: value(of:_:))
        }
        result += records.rowOrders.map { rowOrder($0, databaseId: viewDatabase[$0.viewId]) }
        return result
    }

    // MARK: Значения полей

    static func value(of schema: DatabaseSchema, _ field: DatabaseSchema.Field) -> JSONValue {
        switch field {
        case .isInline: .bool(schema.isInline)
        case .defaultTemplateId: schema.defaultTemplateId.map { .string($0.databaseText) } ?? .null
        }
    }

    static func value(of property: DatabaseProperty, _ field: DatabaseProperty.Field) -> JSONValue {
        switch field {
        case .name: .string(property.name)
        case .typeAndConfig: ["type": .string(property.kind.rawValue), "config": property.config]
        case .sortKey: .string(property.sortKey.rawValue)
        case .deletedAt: date(property.deletedAt)
        }
    }

    static func value(of option: SelectOption, _ field: SelectOption.Field) -> JSONValue {
        switch field {
        case .name: .string(option.name)
        case .color: .string(option.color)
        case .placement:
            .object(["propertyId": .string(option.propertyId.databaseText), "sortKey": .string(option.sortKey.rawValue)]
                .merging(option.statusGroup.map { ["statusGroup": .string($0.rawValue)] } ?? [:]) { $1 })
        case .deletedAt: date(option.deletedAt)
        }
    }

    static func value(of view: DatabaseView, _ field: DatabaseView.Field) -> JSONValue {
        switch field {
        case .name: .string(view.name)
        case .type: .string(view.type)
        case .sortKey: .string(view.sortKey.rawValue)
        case .filter: view.filter ?? .null
        case .sorts: view.sorts
        case .columns: view.columns
        case .group: view.group ?? .null
        case .layoutOptions: view.layoutOptions
        }
    }

    static func value(of link: RelationLink, _ field: RelationLink.Field) -> JSONValue {
        switch field {
        case .link: ["propertyId": .string(link.propertyId.databaseText), "rowId": .string(link.rowId.databaseText),
                     "targetRowId": .string(link.targetRowId.databaseText)]
        case .isPresent: .bool(link.isPresent)
        case .sortKey: .string(link.sortKey.rawValue)
        }
    }

    static func cell(_ cell: CellRecord, databaseId: UUID?) -> SyncChange {
        SyncChange(entity: .cell, id: cell.rowId, pageId: databaseId,
                   value: .databaseField("value", ["propertyId": .string(cell.propertyId.databaseText), "value": cell.value ?? .null]), hlc: cell.hlc)
    }

    static func rowOrder(_ order: RowOrder, databaseId: UUID?) -> SyncChange {
        SyncChange(entity: .rowOrder, id: order.id, pageId: databaseId,
                   value: .databaseField("sortKey", ["viewId": .string(order.viewId.databaseText), "rowId": .string(order.rowId.databaseText),
                                                     "sortKey": .string(order.sortKey.rawValue)]), hlc: order.hlc)
    }

    static func date(_ date: Date?) -> JSONValue {
        date.map { .string($0.formatted(SyncJSON.dateStyle)) } ?? .null
    }

    static func date(_ value: JSONValue) -> Date? {
        guard let text = value.string else { return nil }
        return (try? Date(text, strategy: SyncJSON.dateStyle)) ?? (try? Date(text, strategy: .iso8601))
    }
}
