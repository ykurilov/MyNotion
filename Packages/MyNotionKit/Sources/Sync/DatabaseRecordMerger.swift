import Foundation
import NotesCore

/// Слияние записей баз (research R7, R10): у каждого поля — «позднее побеждает»; варианты и связи — свои записи,
/// поэтому одновременные добавления с двух Mac не теряются. Ячейка, связь или вариант без своей базы, свойства или
/// строки хранятся и показываются, когда придёт недостающее. Неизвестные поля (от более новой версии v4) пропускаются.
struct DatabaseRecordMerger {
    let transaction: NotesTransaction
    /// Страницы, чей вид поменялся: базы и строки.
    private(set) var touchedPageIds: Set<UUID> = []

    init(transaction: NotesTransaction) {
        self.transaction = transaction
    }

    mutating func merge(_ group: [SyncChange]) throws {
        if let pageId = group.lazy.compactMap(\.pageId).first { touchedPageIds.insert(pageId) }
        switch group[0].entity {
        case .database: try mergeDatabase(group)
        case .property: try mergeProperty(group)
        case .option: try mergeOption(group)
        case .view: try mergeView(group)
        case .cell: try mergeCells(group)
        case .relationLink: try mergeRelationLink(group)
        case .rowOrder: try mergeRowOrders(group)
        default: break
        }
    }

    /// Поля, которые нужно взять: у новой записи — все пришедшие, у известной — только более поздние.
    private func winning<Field: Hashable>(_ group: [SyncChange], isNew: Bool, clock: (Field) -> HybridTimestamp?,
                                          field: (String) -> Field?) -> [(Field, JSONValue, HybridTimestamp)] {
        var result: [Field: (JSONValue, HybridTimestamp)] = [:]
        for change in group {
            guard case .databaseField(let name, let value) = change.value, let field = field(name) else { continue }
            if let taken = result[field], taken.1 >= change.hlc { continue }
            if !isNew, change.hlc <= (clock(field) ?? .distantPast) { continue }
            result[field] = (value, change.hlc)
        }
        return result.map { ($0.key, $0.value.0, $0.value.1) }
    }

    private mutating func mergeDatabase(_ group: [SyncChange]) throws {
        let id = group[0].id
        let stored = try transaction.database(id)
        var schema = stored ?? DatabaseSchema(pageId: id)
        let fields = winning(group, isNew: stored == nil, clock: { schema.fieldClocks[$0] }, field: DatabaseSchema.Field.init(rawValue:))
        guard !fields.isEmpty else { return }
        for (field, value, stamp) in fields {
            switch field {
            case .isInline: schema.isInline = value.bool ?? false
            case .defaultTemplateId: schema.defaultTemplateId = value.string.flatMap(UUID.init(uuidString:))
            }
            schema.fieldClocks[field] = stamp
        }
        try transaction.writeReplicatedDatabase(schema, changedFields: Set(fields.map(\.0)), isNew: stored == nil)
    }

    private mutating func mergeProperty(_ group: [SyncChange]) throws {
        let id = group[0].id
        let stored = try transaction.property(id)
        guard let databaseId = stored?.databaseId ?? group.lazy.compactMap(\.pageId).first else { return }
        var property = stored ?? DatabaseProperty(id: id, databaseId: databaseId, name: "", kind: .text, sortKey: .between(nil, nil))
        let fields = winning(group, isNew: stored == nil, clock: { property.fieldClocks[$0] }, field: DatabaseProperty.Field.init(rawValue:))
        guard !fields.isEmpty else { return }
        for (field, value, stamp) in fields {
            switch field {
            case .name: property.name = value.string ?? property.name
            case .typeAndConfig:
                if let type = value["type"]?.string { property.kind = PropertyKind(rawValue: type) }
                property.config = value["config"] ?? .emptyObject
            case .sortKey: if let key = value.string.flatMap(FractionalSortKey.init(rawValue:)) { property.sortKey = key }
            case .deletedAt: property.deletedAt = DatabaseChangeEncoding.date(value)
            }
            property.fieldClocks[field] = stamp
        }
        try transaction.writeReplicatedProperty(property, changedFields: Set(fields.map(\.0)), isNew: stored == nil)
    }

    private mutating func mergeOption(_ group: [SyncChange]) throws {
        let id = group[0].id
        let stored = try transaction.option(id)
        let placement = group.lazy.compactMap { change -> UUID? in
            guard case .databaseField("placement", let value) = change.value else { return nil }
            return value["propertyId"]?.string.flatMap(UUID.init(uuidString:))
        }.first
        guard let propertyId = stored?.propertyId ?? placement else { return }
        var option = stored ?? SelectOption(id: id, propertyId: propertyId, name: "", colorName: OptionColor.default.rawValue,
                                            sortKey: .between(nil, nil), statusGroup: nil, deletedAt: nil, fieldClocks: .init())
        let fields = winning(group, isNew: stored == nil, clock: { option.fieldClocks[$0] }, field: SelectOption.Field.init(rawValue:))
        guard !fields.isEmpty else { return }
        for (field, value, stamp) in fields {
            switch field {
            case .name: option.name = value.string ?? option.name
            case .color: option.color = value.string ?? option.color
            case .placement:
                if let key = value["sortKey"]?.string.flatMap(FractionalSortKey.init(rawValue:)) { option.sortKey = key }
                option.statusGroup = value["statusGroup"]?.string.flatMap(StatusGroup.init(rawValue:))
            case .deletedAt: option.deletedAt = DatabaseChangeEncoding.date(value)
            }
            option.fieldClocks[field] = stamp
        }
        try transaction.writeReplicatedOption(option, changedFields: Set(fields.map(\.0)), isNew: stored == nil)
    }

    private mutating func mergeView(_ group: [SyncChange]) throws {
        let id = group[0].id
        let stored = try transaction.view(id)
        guard let databaseId = stored?.databaseId ?? group.lazy.compactMap(\.pageId).first else { return }
        var view = stored ?? DatabaseView(id: id, databaseId: databaseId, sortKey: .between(nil, nil))
        let fields = winning(group, isNew: stored == nil, clock: { view.fieldClocks[$0] }, field: DatabaseView.Field.init(rawValue:))
        guard !fields.isEmpty else { return }
        for (field, value, stamp) in fields {
            switch field {
            case .name: view.name = value.string ?? view.name
            case .type: view.type = value.string ?? view.type
            case .sortKey: if let key = value.string.flatMap(FractionalSortKey.init(rawValue:)) { view.sortKey = key }
            case .filter: view.filter = value == .null ? nil : value
            case .sorts: view.sorts = value
            case .columns: view.columns = value
            case .group: view.group = value == .null ? nil : value
            case .layoutOptions: view.layoutOptions = value
            }
            view.fieldClocks[field] = stamp
        }
        try transaction.writeReplicatedView(view, changedFields: Set(fields.map(\.0)), isNew: stored == nil)
    }

    /// Ячейки строки: у каждой своя метка, ключ — `(строка, свойство)`.
    private mutating func mergeCells(_ group: [SyncChange]) throws {
        let rowId = group[0].id
        touchedPageIds.insert(rowId)
        var latest: [UUID: (JSONValue, HybridTimestamp)] = [:]
        for change in group {
            guard case .databaseField("value", let value) = change.value,
                  let propertyId = value["propertyId"]?.string.flatMap(UUID.init(uuidString:)) else { continue }
            if let taken = latest[propertyId], taken.1 >= change.hlc { continue }
            latest[propertyId] = (value["value"] ?? .null, change.hlc)
        }
        for (propertyId, (value, stamp)) in latest {
            let stored = try transaction.cell(rowId: rowId, propertyId: propertyId)
            guard stamp > (stored?.hlc ?? .distantPast) || stored == nil else { continue }
            try transaction.writeReplicatedCell(CellRecord(rowId: rowId, propertyId: propertyId, value: value == .null ? nil : value, hlc: stamp))
        }
    }

    private mutating func mergeRelationLink(_ group: [SyncChange]) throws {
        let id = group[0].id
        let stored = try transaction.relationLink(id)
        var link: RelationLink
        if let stored {
            link = stored
        } else {
            guard let payload = group.lazy.compactMap({ change -> JSONValue? in
                if case .databaseField("link", let value) = change.value { value } else { nil }
            }).first, let propertyId = payload["propertyId"]?.string.flatMap(UUID.init(uuidString:)),
                  let rowId = payload["rowId"]?.string.flatMap(UUID.init(uuidString:)),
                  let targetRowId = payload["targetRowId"]?.string.flatMap(UUID.init(uuidString:)) else { return }
            link = RelationLink(propertyId: propertyId, rowId: rowId, targetRowId: targetRowId, sortKey: .between(nil, nil))
            // id выводится из сторон связи: чужой id с другими сторонами — не та запись.
            guard link.id == id else { return }
        }
        let fields = winning(group, isNew: stored == nil, clock: { link.fieldClocks[$0] }, field: RelationLink.Field.init(rawValue:))
        guard !fields.isEmpty else { return }
        for (field, value, stamp) in fields {
            switch field {
            case .link: break
            case .isPresent: link.isPresent = value.bool ?? link.isPresent
            case .sortKey: if let key = value.string.flatMap(FractionalSortKey.init(rawValue:)) { link.sortKey = key }
            }
            link.fieldClocks[field] = stamp
        }
        touchedPageIds.formUnion([link.rowId, link.targetRowId])
        try transaction.writeReplicatedRelationLink(link, changedFields: Set(fields.map(\.0)), isNew: stored == nil)
    }

    private mutating func mergeRowOrders(_ group: [SyncChange]) throws {
        for change in group {
            guard case .databaseField("sortKey", let value) = change.value,
                  let viewId = value["viewId"]?.string.flatMap(UUID.init(uuidString:)),
                  let rowId = value["rowId"]?.string.flatMap(UUID.init(uuidString:)),
                  let key = value["sortKey"]?.string.flatMap(FractionalSortKey.init(rawValue:)) else { continue }
            let stored = try transaction.rowOrder(viewId: viewId, rowId: rowId)
            guard stored == nil || change.hlc > stored!.hlc else { continue }
            try transaction.writeReplicatedRowOrder(RowOrder(viewId: viewId, rowId: rowId, sortKey: key, hlc: change.hlc))
        }
    }
}
