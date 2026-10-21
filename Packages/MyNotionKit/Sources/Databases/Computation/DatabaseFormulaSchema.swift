import Foundation
import Formulas
import GRDB
import NotesCore

/// Схема базы глазами формул: свойства своей базы и баз, куда ведут связи (обход `current.prop(…)`), — для проверки
/// формулы, «Тип: …», списка свойств в редакторе и замены названий на id (contracts/formulas.md, «`prop` отдаёт»).
public struct DatabaseFormulaSchema: FormulaSchema {
    public let databaseId: UUID
    let catalogs: [UUID: DatabaseCatalog]

    public init(databaseId: UUID, catalogs: [UUID: DatabaseCatalog]) {
        self.databaseId = databaseId
        self.catalogs = catalogs
    }

    /// Своя база и все базы, достижимые по связям.
    public static func read(_ databaseId: UUID, in db: Database) throws -> DatabaseFormulaSchema {
        var catalogs: [UUID: DatabaseCatalog] = [:]
        var queue = [databaseId]
        while let next = queue.popLast(), catalogs[next] == nil, catalogs.count < 32 {
            let catalog = try DatabaseCatalog.read(next, in: db)
            catalogs[next] = catalog
            queue += catalog.properties.compactMap(\.relationTarget).filter { catalogs[$0] == nil }
        }
        return DatabaseFormulaSchema(databaseId: databaseId, catalogs: catalogs)
    }

    public static func read(_ databaseId: UUID, in store: NotesStore) throws -> DatabaseFormulaSchema {
        try store.database.dbWriter.read { try read(databaseId, in: $0) }
    }

    /// Свойства своей базы по порядку — список «Свойства» редактора.
    public var properties: [FormulaProperty] { (catalogs[databaseId]?.properties ?? []).map(Self.formulaProperty) }

    public func property(_ nameOrId: String, inDatabase database: String?) -> FormulaProperty? {
        let id = database.flatMap(UUID.init(uuidString:)) ?? (database == nil ? databaseId : nil)
        guard let id, let catalog = catalogs[id] else { return nil }
        let match = catalog.properties.first { $0.id.databaseText == nameOrId.lowercased() } ?? catalog.properties.first { $0.name == nameOrId }
        return match.map(Self.formulaProperty)
    }

    /// База свойства (по id) среди прочитанных.
    public func databaseId(ofProperty id: String) -> UUID? {
        catalogs.first { $0.value.properties.contains { $0.id.databaseText == id } }?.key
    }

    /// Свойство и тип его значения в формуле.
    public static func formulaProperty(_ property: DatabaseProperty) -> FormulaProperty {
        let type: FormulaType
        var supported = true
        switch property.kind {
        case .title, .text, .url, .email, .phone, .select, .status: type = .text
        case .number, .uniqueId: type = .number
        case .multiSelect, .files: type = .list(.text)
        case .date, .createdTime, .lastEditedTime: type = .date
        case .checkbox: type = .bool
        case .relation: type = .list(.page(database: property.relationTarget?.databaseText))
        case .rollup, .formula: type = .any
        default:
            type = .any
            supported = false
        }
        return FormulaProperty(id: property.id.databaseText, name: property.name, type: type,
                               formula: property.kind == .formula ? (property.config["expression"]?.string ?? "") : nil, isSupported: supported)
    }
}

extension DatabaseProperty {
    /// База, куда ведёт связь.
    var relationTarget: UUID? {
        kind == .relation ? config["targetDatabaseId"]?.string.flatMap(UUID.init(uuidString:)) : nil
    }

    /// Ответное свойство двусторонней связи.
    var pairedRelation: UUID? { config["pairedPropertyId"]?.string.flatMap(UUID.init(uuidString:)) }

    /// Ссылки двусторонней пары хранятся у свойства с меньшим id: у «второго» свойства пара читается наоборот
    /// (как в `FormulaInputs`).
    var readsLinksReversed: Bool { pairedRelation.map { $0.uuidString < id.uuidString } ?? false }
}
