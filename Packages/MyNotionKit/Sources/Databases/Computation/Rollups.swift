import Foundation
import GRDB
import NotesCore

/// Сводки базы (research R8, contracts/property-types.md, «Итоги колонки и вычисления сводки»): по связи — значения
/// свойства живых связанных строк и вычисление из набора Notion. Итог — в `db_computed`, как у формул. Две дороги, как у
/// `FormulaRecompute`: правка — `recompute(rows:in:)` в той же транзакции (подписчик `ComputationHook`); новая сводка,
/// смена её настройки, корзина базы-цели — `recomputeAll()` в фоне пачками (очередь `FormulaRecomputeQueue`).
public struct RollupRecompute: Sendable {
    struct Rollup: Sendable {
        let property: DatabaseProperty
        let relation: DatabaseProperty
        /// Свойство базы-цели; нет — сводка пустая.
        let target: DatabaseProperty?
        let targetCatalog: DatabaseCatalog?
        let calculation: Calculation
    }

    public let databaseId: UUID
    let rollups: [Rollup]
    let calendar: Calendar

    /// Сводки базы (все или те, что зависят от `propertyIds`: сама сводка, её связь или свойство цели).
    public init(catalog: DatabaseCatalog, propertyIds: Set<UUID>? = nil, calendar: Calendar = .current, in db: Database) throws {
        databaseId = catalog.databaseId
        self.calendar = calendar
        var targetCatalogs: [UUID: DatabaseCatalog] = [:]
        var rollups: [Rollup] = []
        for property in catalog.properties where property.kind == .rollup {
            guard let relationId = property.config["relationPropertyId"]?.string.flatMap(UUID.init(uuidString:)),
                  let relation = catalog.propertiesById[relationId], relation.kind == .relation, let targetDatabase = relation.relationTarget
            else { continue }
            let targetId = property.config["targetPropertyId"]?.string.flatMap(UUID.init(uuidString:))
            if let propertyIds, !propertyIds.contains(property.id), !propertyIds.contains(relationId), !(targetId.map(propertyIds.contains) ?? false) {
                continue
            }
            if targetCatalogs[targetDatabase] == nil { targetCatalogs[targetDatabase] = try DatabaseCatalog.read(targetDatabase, in: db) }
            let targetCatalog = targetCatalogs[targetDatabase]
            rollups.append(Rollup(property: property, relation: relation, target: targetId.flatMap { targetCatalog?.propertiesById[$0] },
                                  targetCatalog: targetCatalog,
                                  calculation: property.config["calculation"]?.string.flatMap(Calculation.init(rawValue:)) ?? .showOriginal))
        }
        self.rollups = rollups
    }

    public var isEmpty: Bool { rollups.isEmpty }
    public var propertyIds: Set<UUID> { Set(rollups.map(\.property.id)) }

    /// Итоги сводок строк `rows`.
    func values(_ rows: [UUID], in db: Database) throws -> [ComputedValue] {
        var result: [ComputedValue] = []
        for group in Dictionary(grouping: rollups, by: \.relation.id).values {
            let links = try RelationLinks.targets(of: rows, through: group[0].relation, in: db)
            let targetRows = Array(Set(links.values.flatMap { $0.map(\.id) }))
            for rollup in group {
                guard let target = rollup.target, let catalog = rollup.targetCatalog else {
                    result += rows.map { ComputedValue(rowId: $0, propertyId: rollup.property.id, value: nil) }
                    continue
                }
                let values = try Self.values(of: target, rows: targetRows, catalog: catalog, calendar: calendar, in: db)
                let context = catalog.context(for: target, calendar: calendar)
                for row in rows {
                    let list = (links[row] ?? []).map { values[$0.id] ?? (target.kind == .checkbox ? .bool(false) : nil) }
                    var value = Calculations.compute(rollup.calculation, values: list, in: context)
                    if value?.array?.isEmpty == true { value = nil }
                    result.append(ComputedValue(rowId: row, propertyId: rollup.property.id, value: value))
                }
            }
        }
        return result
    }

    /// Правка строк: итоги сводок в транзакции правки.
    public func recompute(rows: [UUID], in transaction: NotesTransaction) throws {
        guard !rollups.isEmpty, !rows.isEmpty else { return }
        try ComputedWriter.write(values(rows, in: transaction.database), in: transaction)
    }

    /// Все строки базы в фоне (не с главного потока): пачками по `batch` строк, чтение и запись пачки — одной записью.
    /// Иначе правка цели между чтением и записью (её сводки посчитаны в ней же) затиралась бы прочитанным раньше:
    /// ⌘Z фоновой смены типа оставлял сводку пустой.
    public func recomputeAll(in store: NotesStore, batch: Int = 100) throws {
        guard !rollups.isEmpty else { return }
        let rows = try store.database.dbWriter.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM page WHERE parentId = ? AND trashedAt IS NULL ORDER BY sortKey",
                                arguments: [databaseId.databaseText]).compactMap(UUID.init(uuidString:))
        }
        for start in stride(from: 0, to: rows.count, by: batch) {
            let chunk = Array(rows[start..<min(start + batch, rows.count)])
            try store.database.dbWriter.write { db in try ComputedWriter.write(self.values(chunk, in: db), in: db) }
        }
    }

    // MARK: Значения цели

    /// Значение свойства у строк цели — в виде для вычисления и показа: варианты и текст — названиями, связь —
    /// `[{id, title}]`, даты строки — дата со временем, итоги формул и сводок — как есть.
    static func values(of property: DatabaseProperty, rows: [UUID], catalog: DatabaseCatalog, calendar: Calendar,
                       in db: Database) throws -> [UUID: JSONValue] {
        guard !rows.isEmpty else { return [:] }
        var result: [UUID: JSONValue] = [:]
        switch property.kind {
        case .relation:
            for (row, related) in try RelationLinks.targets(of: rows, through: property, in: db) {
                result[row] = .array(related.map { ["id": .string($0.id.databaseText), "title": .string($0.title)] })
            }
        case .title, .createdTime, .lastEditedTime:
            let context = catalog.context(for: property, calendar: calendar)
            try forEachChunk(rows) { marks, arguments in
                for row in try Row.fetchAll(db, sql: "SELECT id, title, createdAt, updatedAt FROM page WHERE id IN (\(marks))", arguments: arguments) {
                    guard let id = UUID(uuidString: row[0]) else { continue }
                    switch property.kind {
                    case .title:
                        let title: String = row[1]
                        if !title.isEmpty { result[id] = .string(title) }
                    case .createdTime: result[id] = PropertyValue.pageDate(row[2], in: context)
                    default: result[id] = PropertyValue.pageDate(row[3], in: context)
                    }
                }
            }
        default:
            let table = property.kind == .formula || property.kind == .rollup ? "db_computed" : "db_cell"
            try forEachChunk(rows) { marks, arguments in
                let cursor = try Row.fetchCursor(db, sql: """
                    SELECT rowId, value FROM \(table) WHERE propertyId = ? AND rowId IN (\(marks)) AND value IS NOT NULL
                    """, arguments: StatementArguments([property.id.databaseText]) + arguments)
                while let row = try cursor.next() {
                    guard let id = UUID(uuidString: row[0]), let text: String = row[1], let json = FastJSON.parse(text),
                          let value = normalized(json, property: property, catalog: catalog) else { continue }
                    result[id] = value
                }
            }
        }
        return result
    }

    /// Значение ячейки — в виде для сводки.
    static func normalized(_ json: JSONValue, property: DatabaseProperty, catalog: DatabaseCatalog) -> JSONValue? {
        func optionName(_ value: JSONValue) -> JSONValue? {
            value.string.flatMap(UUID.init(uuidString:)).flatMap { catalog.optionsById[$0]?.name }.map(JSONValue.string)
        }
        switch property.kind {
        case .select, .status: return optionName(json)
        case .multiSelect: return .array((json.array ?? []).compactMap(optionName))
        case .text:
            let text = TextType.string(json)
            return text.isEmpty ? nil : .string(text)
        case .files: return .array(FilesType.names(json).map(JSONValue.string))
        case .url, .email, .phone: return json.string.flatMap { $0.isEmpty ? nil : .string($0) }
        default: return json
        }
    }

    private static func forEachChunk(_ rows: [UUID], _ body: (String, StatementArguments) throws -> Void) throws {
        for start in stride(from: 0, to: rows.count, by: 500) {
            let chunk = rows[start..<min(start + 500, rows.count)]
            try body(Array(repeating: "?", count: chunk.count).joined(separator: ","), StatementArguments(chunk.map(\.databaseText)))
        }
    }
}
