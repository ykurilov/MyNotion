import Foundation
import Formulas
import GRDB
import NotesCore

/// Что зависит от чего в базах (research R6): у базы — формулы по порядку, свойства своей строки, от которых они
/// зависят, и свойства чужих строк через связи; у каждой базы — связи, которые ведут в неё из других баз.
struct ComputationGraph: Sendable {
    struct DatabaseFormulas: Sendable {
        let catalog: DatabaseCatalog
        /// Свои свойства из формул (и сами формулы, на которые ссылаются другие).
        let ownDependencies: Set<UUID>
        /// Чужие свойства (`current.prop(…)`) — по связям этой базы.
        let foreignDependencies: Set<UUID>
        /// Есть «Изменено» или «Создано»: любая правка строки меняет итог.
        let dependsOnRowTimes: Bool
        let formulaIds: Set<UUID>

        var isEmpty: Bool { formulaIds.isEmpty }

        /// Связи этой базы, по которым формулы читают чужие строки.
        var usedRelations: [DatabaseProperty] { catalog.properties.filter { $0.kind == .relation && ownDependencies.contains($0.id) } }
    }

    /// Формулы базы; базы без формул — пустые.
    private(set) var formulas: [UUID: DatabaseFormulas] = [:]
    /// База → связи из других баз, ведущие в неё (`relation.databaseId` — база с формулами).
    private(set) var relationsInto: [UUID: [DatabaseProperty]] = [:]
    /// Свойство → база.
    private(set) var databaseOfProperty: [UUID: UUID] = [:]

    /// Всё по базам, где есть формулы, и по связям.
    static func read(in db: Database) throws -> ComputationGraph {
        var graph = ComputationGraph()
        let properties = try Row.fetchAll(db, sql: "SELECT * FROM db_property WHERE deletedAt IS NULL AND type IN ('formula', 'relation')")
            .map(DatabaseProperty.init(row:))
        for property in properties {
            graph.databaseOfProperty[property.id] = property.databaseId
            if let target = property.relationTarget { graph.relationsInto[target, default: []].append(property) }
        }
        for databaseId in Set(properties.filter { $0.kind == .formula }.map(\.databaseId)) {
            graph.formulas[databaseId] = try formulas(of: try DatabaseCatalog.read(databaseId, in: db))
        }
        return graph
    }

    static func formulas(of catalog: DatabaseCatalog) throws -> DatabaseFormulas {
        var own: Set<UUID> = [], foreign: Set<UUID> = [], formulaIds: Set<UUID> = []
        for property in catalog.properties where property.kind == .formula {
            formulaIds.insert(property.id)
            guard let text = property.config["expression"]?.string, let expression = try? FormulaParser.parse(text) else { continue }
            for reference in expression.referencedProperties {
                guard let id = UUID(uuidString: reference) else { continue }
                if catalog.propertiesById[id] != nil { own.insert(id) } else { foreign.insert(id) }
            }
        }
        let rowTimes = own.contains { [.lastEditedTime, .createdTime].contains(catalog.propertiesById[$0]?.kind) }
        return DatabaseFormulas(catalog: catalog, ownDependencies: own, foreignDependencies: foreign, dependsOnRowTimes: rowTimes, formulaIds: formulaIds)
    }

    /// Базы, чьи формулы читают свойства `changed` строк базы `databaseId` по связям: связь и её база.
    func readers(of databaseId: UUID, changed: Set<UUID>?) -> [(relation: DatabaseProperty, formulas: DatabaseFormulas)] {
        (relationsInto[databaseId] ?? []).compactMap { relation in
            guard let formulas = formulas[relation.databaseId], formulas.ownDependencies.contains(relation.id) else { return nil }
            if let changed, formulas.foreignDependencies.isDisjoint(with: changed) { return nil }
            return (relation, formulas)
        }
    }
}

extension ComputationGraph {
    /// Строки базы связи `relation`, которые ссылаются на строки `targets`.
    static func rows(linkingTo targets: Set<UUID>, through relation: DatabaseProperty, in db: Database) throws -> Set<UUID> {
        guard !targets.isEmpty else { return [] }
        let marks = Array(repeating: "?", count: targets.count).joined(separator: ",")
        let (linkProperty, own, other) = relation.readsLinksReversed ? (relation.pairedRelation!, "targetRowId", "rowId") : (relation.id, "rowId", "targetRowId")
        let ids = try String.fetchAll(db, sql: """
            SELECT \(own) FROM db_relation_link WHERE propertyId = ? AND \(other) IN (\(marks)) AND isPresent = 1
            """, arguments: StatementArguments([linkProperty.databaseText] + targets.map(\.databaseText)))
        return Set(ids.compactMap(UUID.init(uuidString:)))
    }
}
