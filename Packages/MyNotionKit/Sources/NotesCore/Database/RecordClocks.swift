import Foundation

/// Метки часов полей записи базы (data-model.md, `fieldClocks`): у каждого синхронизируемого поля своя.
public struct RecordClocks<Field: RawRepresentable & Hashable & CaseIterable & Sendable>: Sendable, Hashable
where Field.RawValue == String {
    public private(set) var stamps: [Field: HybridTimestamp] = [:]

    public init(_ stamps: [Field: HybridTimestamp] = [:]) {
        self.stamps = stamps
    }

    public subscript(field: Field) -> HybridTimestamp? {
        get { stamps[field] }
        set { stamps[field] = newValue }
    }

    public mutating func stamp(_ fields: Set<Field>, with timestamp: HybridTimestamp) {
        for field in fields { stamps[field] = timestamp }
    }

    public var all: [HybridTimestamp] { Array(stamps.values) }

    /// `{"поле":"метка",…}` по алфавиту, как метки страниц и блоков.
    var databaseJSON: String {
        JSONColumn.encodeClocks(Field.allCases.map { ($0.rawValue, stamps[$0]) })
    }

    init(databaseJSON text: String) {
        var stamps: [Field: HybridTimestamp] = [:]
        let isPlain = JSONColumn.decodeClocks(text) { name, stamp in
            if let field = Field(rawValue: String(decoding: Array(name), as: UTF8.self)) { stamps[field] = stamp }
        }
        if !isPlain, let decoded = try? JSONDecoder().decode([String: String].self, from: Data(text.utf8)) {
            for (name, raw) in decoded {
                if let field = Field(rawValue: name), let stamp = HybridTimestamp(raw) { stamps[field] = stamp }
            }
        }
        self.stamps = stamps
    }
}

extension UUID {
    /// UUID версии 5 (RFC 9562, SHA-1) из пространства и имени: одна и та же связь или место строки, созданные
    /// на двух Mac, получают один id (data-model.md, `db_relation_link`, `db_row_order`).
    public static func derived(_ namespace: UUID, _ parts: UUID...) -> UUID {
        DerivedID.make(namespace: namespace, name: parts.map(\.databaseText).joined(separator: ":"))
    }
}
