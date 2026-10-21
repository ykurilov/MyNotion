import Foundation

/// Значение ячейки (data-model.md, `db_cell`): одна запись с одной меткой часов на пару «строка — свойство».
/// Пустое значение остаётся записью с меткой (`value == nil`): иначе более старое значение с другого Mac
/// вернулось бы после очистки.
public struct CellRecord: Sendable, Hashable {
    public let rowId: UUID
    public let propertyId: UUID
    /// JSON по типу (data-model.md, «value по типам»); `nil` — пусто.
    public var value: JSONValue?
    public var hlc: HybridTimestamp

    public init(rowId: UUID, propertyId: UUID, value: JSONValue?, hlc: HybridTimestamp) {
        self.rowId = rowId
        self.propertyId = propertyId
        self.value = value
        self.hlc = hlc
    }
}

/// Связь двух строк (data-model.md, `db_relation_link`): своя запись, id выведен из `(свойство, строка, цель)`.
public struct RelationLink: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let propertyId: UUID
    public let rowId: UUID
    public let targetRowId: UUID
    public var sortKey: FractionalSortKey
    /// `false` — связь снята; запись остаётся до чистки следов.
    public var isPresent: Bool
    public var fieldClocks: RecordClocks<Field>

    public init(propertyId: UUID, rowId: UUID, targetRowId: UUID, sortKey: FractionalSortKey, isPresent: Bool = true,
                fieldClocks: RecordClocks<Field> = .init()) {
        self.id = Self.id(propertyId: propertyId, rowId: rowId, targetRowId: targetRowId)
        self.propertyId = propertyId
        self.rowId = rowId
        self.targetRowId = targetRowId
        self.sortKey = sortKey
        self.isPresent = isPresent
        self.fieldClocks = fieldClocks
    }

    public static func id(propertyId: UUID, rowId: UUID, targetRowId: UUID) -> UUID {
        DerivedID.make(namespace: DerivedID.relationLinks,
                       name: [propertyId, rowId, targetRowId].map(\.databaseText).joined(separator: ":"))
    }

    public enum Field: String, Sendable, Hashable, CaseIterable, Codable {
        /// Сама связь: свойство, строка, цель — один раз, при создании.
        case link
        case isPresent
        case sortKey
    }

    public func changedFields(comparedTo old: RelationLink) -> Set<Field> {
        var fields: Set<Field> = []
        if isPresent != old.isPresent { fields.insert(.isPresent) }
        if sortKey != old.sortKey { fields.insert(.sortKey) }
        return fields
    }
}

/// Ручной порядок строки в виде (data-model.md, `db_row_order`).
public struct RowOrder: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let viewId: UUID
    public let rowId: UUID
    public var sortKey: FractionalSortKey
    public var hlc: HybridTimestamp

    public init(viewId: UUID, rowId: UUID, sortKey: FractionalSortKey, hlc: HybridTimestamp) {
        self.id = Self.id(viewId: viewId, rowId: rowId)
        self.viewId = viewId
        self.rowId = rowId
        self.sortKey = sortKey
        self.hlc = hlc
    }

    public static func id(viewId: UUID, rowId: UUID) -> UUID {
        DerivedID.make(namespace: DerivedID.rowOrders, name: [viewId, rowId].map(\.databaseText).joined(separator: ":"))
    }
}
