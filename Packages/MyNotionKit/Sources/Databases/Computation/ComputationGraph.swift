import Foundation
import Formulas
import GRDB
import NotesCore

/// Что зависит от чего в базах (research R6, R8): у базы — формулы и сводки, свойства своей строки, от которых они
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
        /// Сводки базы: своя зависимость — связь, чужая — свойство цели.
        let rollupIds: Set<UUID>
        /// Связь → непосредственно читающие её формулы и сводки; зависимые формулы добавляет FormulaRecompute.
        let relationReaders: [UUID: Set<UUID>]

        /// Формулы и сводки — всё, что считается в `db_computed`.
        var computedIds: Set<UUID> { formulaIds.union(rollupIds) }
        var isEmpty: Bool { computedIds.isEmpty }

        /// Связи этой базы, по которым формулы читают чужие строки.
        var usedRelations: [DatabaseProperty] { catalog.properties.filter { $0.kind == .relation && ownDependencies.contains($0.id) } }
    }

    /// Формулы базы; базы без формул — пустые.
    private(set) var formulas: [UUID: DatabaseFormulas] = [:]
    /// База → связи из других баз, ведущие в неё (`relation.databaseId` — база с формулами).
    private(set) var relationsInto: [UUID: [DatabaseProperty]] = [:]
    /// Свойство → база.
    private(set) var databaseOfProperty: [UUID: UUID] = [:]
    private var titleProperties: Set<UUID> = []

    /// Всё по базам, где есть формулы или сводки, и по связям.
    static func read(in db: Database) throws -> ComputationGraph {
        var graph = ComputationGraph()
        let properties = try Row.fetchAll(db, sql: "SELECT * FROM db_property WHERE deletedAt IS NULL AND type IN ('formula', 'relation', 'rollup', 'title')")
            .map(DatabaseProperty.init(row:))
        graph.titleProperties = Set(properties.filter { $0.kind == .title }.map(\.id))
        for property in properties {
            graph.databaseOfProperty[property.id] = property.databaseId
            if let target = property.relationTarget { graph.relationsInto[target, default: []].append(property) }
        }
        for databaseId in Set(properties.filter { $0.kind == .formula || $0.kind == .rollup }.map(\.databaseId)) {
            graph.formulas[databaseId] = try formulas(of: try DatabaseCatalog.read(databaseId, in: db))
        }
        return graph
    }

    static func formulas(of catalog: DatabaseCatalog) throws -> DatabaseFormulas {
        var own: Set<UUID> = [], foreign: Set<UUID> = [], formulaIds: Set<UUID> = []
        var relationReaders: [UUID: Set<UUID>] = [:]
        for property in catalog.properties where property.kind == .formula {
            formulaIds.insert(property.id)
            guard let text = property.config["expression"]?.string, let expression = try? FormulaParser.parse(text) else { continue }
            for reference in expression.referencedProperties {
                guard let id = UUID(uuidString: reference) else { continue }
                if let source = catalog.propertiesById[id] {
                    own.insert(id)
                    if source.kind == .relation { relationReaders[id, default: []].insert(property.id) }
                } else { foreign.insert(id) }
            }
        }
        let rowTimes = own.contains { [.lastEditedTime, .createdTime].contains(catalog.propertiesById[$0]?.kind) }
        var rollupIds: Set<UUID> = []
        for property in catalog.properties where property.kind == .rollup {
            rollupIds.insert(property.id)
            if let relation = property.config["relationPropertyId"]?.string.flatMap(UUID.init(uuidString:)) {
                own.insert(relation)
                relationReaders[relation, default: []].insert(property.id)
            }
            if let target = property.config["targetPropertyId"]?.string.flatMap(UUID.init(uuidString:)) { foreign.insert(target) }
        }
        return DatabaseFormulas(catalog: catalog, ownDependencies: own, foreignDependencies: foreign, dependsOnRowTimes: rowTimes,
                                formulaIds: formulaIds, rollupIds: rollupIds, relationReaders: relationReaders)
    }

    /// Базы, чьи формулы и сводки читают свойства `changed` строк базы `databaseId` по связям: связь и её база.
    func readers(of databaseId: UUID, changed: Set<UUID>?) -> [(relation: DatabaseProperty, formulas: DatabaseFormulas)] {
        (relationsInto[databaseId] ?? []).compactMap { relation in
            guard let formulas = formulas[relation.databaseId], formulas.ownDependencies.contains(relation.id) else { return nil }
            // format/join страницы читают её отображаемое имя без явного current.prop(«Название»).
            if let changed, formulas.foreignDependencies.isDisjoint(with: changed), changed.isDisjoint(with: titleProperties) { return nil }
            return (relation, formulas)
        }
    }

    /// Порядок пересчёта баз: та, что читает другую по связи, — после неё; круг (базы читают друг друга) — в прежнем порядке.
    func readingOrder(_ databases: [UUID]) -> [UUID] {
        func reads(_ reader: UUID, _ source: UUID) -> Bool {
            (relationsInto[source] ?? []).contains { $0.databaseId == reader && formulas[reader]?.ownDependencies.contains($0.id) == true }
        }
        var result: [UUID] = [], rest = databases
        while !rest.isEmpty {
            let ready = rest.filter { reader in !rest.contains { $0 != reader && reads(reader, $0) } }
            let next = ready.isEmpty ? [rest[0]] : ready
            result += next
            rest.removeAll { next.contains($0) }
        }
        return result
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
