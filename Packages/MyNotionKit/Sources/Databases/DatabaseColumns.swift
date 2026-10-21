import Foundation
import NotesCore

/// Колонки вида (data-model.md, `db_view.columns`): `[{propertyId, isVisible, width, wrap, calculation?}]` по порядку;
/// свойства не из списка — видимые, в конце, ширина по умолчанию. Неизвестные ключи колонки сохраняются.
public enum DatabaseColumns {
    /// Ширины по умолчанию (contracts/database-ui.md, «Шапка колонок»; снимок Notion 7.39: 222 и 159 px ≈ 280 и 200 pt).
    public static let titleWidth: Double = 280
    public static let defaultWidth: Double = 200
    /// Уже колонку не сузить.
    public static let minimumWidth: Double = 100

    public static func defaultWidth(of kind: PropertyKind) -> Double { kind == .title ? titleWidth : defaultWidth }

    /// Ширина колонки свойства в виде.
    public static func width(of property: DatabaseProperty, in view: DatabaseView) -> Double {
        entry(property.id, in: view.columns)?["width"]?.number ?? defaultWidth(of: property.kind)
    }

    static func entry(_ propertyId: UUID, in columns: JSONValue) -> JSONValue? {
        (columns.array ?? []).first { $0["propertyId"]?.string.flatMap(UUID.init(uuidString:)) == propertyId }
    }

    /// Колонки вида в полном списке: все неудалённые свойства по порядку показа (видимые и скрытые), каждая — запись.
    /// Правки колонок идут через этот список, чтобы свойства «не из списка» не перескакивали при первой правке.
    static func normalized(_ view: DatabaseView, catalog: DatabaseCatalog) -> [JSONValue] {
        var entries: [JSONValue] = []
        var listed: Set<UUID> = []
        for column in view.columns.array ?? [] {
            guard let id = column["propertyId"]?.string.flatMap(UUID.init(uuidString:)), !listed.contains(id) else { continue }
            listed.insert(id)
            entries.append(column)
        }
        for property in catalog.properties where !listed.contains(property.id) {
            entries.append(["propertyId": .string(property.id.databaseText), "isVisible": true])
        }
        // «Название» всегда первое (FR-305).
        if let title = catalog.titleProperty, let index = entries.firstIndex(where: { id(of: $0) == title.id }), index > 0 {
            entries.insert(entries.remove(at: index), at: 0)
        }
        return entries
    }

    static func id(of entry: JSONValue) -> UUID? { entry["propertyId"]?.string.flatMap(UUID.init(uuidString:)) }

    static func setting(_ key: String, to value: JSONValue?, in entry: JSONValue) -> JSONValue {
        guard case .object(var object) = entry else { return entry }
        object[key] = value
        return .object(object)
    }
}
