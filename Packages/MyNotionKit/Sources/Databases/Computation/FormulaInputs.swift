import Foundation
import Formulas
import GRDB
import NotesCore

/// Значения, нужные формулам пачки строк: свойства из деревьев формул у своих строк и у строк из связей
/// (`current.prop(…)`). Одно чтение на пачку, без лишних свойств (проба R20.3).
struct FormulaInputs: FormulaContext {
    var values: [UUID: [String: FormulaValue]] = [:]
    /// `updatedAt` строк при чтении — для сверки при записи (R21).
    var stamps: [UUID: String] = [:]
    /// Названия прочитанных строк — `format` и `join` списка страниц.
    var titles: [UUID: String] = [:]
    let now: Date
    let calendar: Calendar

    init(rows: [UUID], needed: Set<String>, catalog: DatabaseCatalog, now: Date, calendar: Calendar, in db: Database) throws {
        self.now = now
        self.calendar = calendar
        guard !rows.isEmpty else { return }
        let own = catalog.properties.filter { needed.contains($0.id.databaseText) }
        try readPages(rows, catalog: catalog, properties: own, in: db)
        try readCells(rows, properties: own, catalog: catalog, in: db)
        // Связи: страницы цели и нужные свойства целей.
        let foreign = needed.subtracting(catalog.properties.map(\.id.databaseText))
        for relation in own where relation.kind == .relation {
            var targets: [UUID: [UUID]] = [:]
            let (linkProperty, ownColumn, otherColumn) = relation.readsLinksReversed ? (relation.pairedRelation!, "targetRowId", "rowId")
                : (relation.id, "rowId", "targetRowId")
            let marks = Array(repeating: "?", count: rows.count).joined(separator: ",")
            for row in try Row.fetchAll(db, sql: """
                SELECT l.\(ownColumn), l.\(otherColumn) FROM db_relation_link l JOIN page t ON t.id = l.\(otherColumn)
                WHERE l.propertyId = ? AND l.\(ownColumn) IN (\(marks)) AND l.isPresent = 1 AND t.trashedAt IS NULL ORDER BY l.sortKey, l.id
                """, arguments: StatementArguments([linkProperty.databaseText] + rows.map(\.databaseText))) {
                guard let from = UUID(uuidString: row[0]), let to = UUID(uuidString: row[1]) else { continue }
                targets[from, default: []].append(to)
            }
            for row in rows { values[row, default: [:]][relation.id.databaseText] = .list((targets[row] ?? []).map(FormulaValue.page)) }
            let targetRows = Array(Set(targets.values.flatMap { $0 }))
            guard !targetRows.isEmpty, let targetDatabase = relation.relationTarget else { continue }
            // Без чужих свойств — только названия (`format`, `join` страниц).
            guard !foreign.isEmpty else { try readPages(targetRows, catalog: catalog, properties: [], in: db); continue }
            let targetCatalog = try DatabaseCatalog.read(targetDatabase, in: db)
            let targetProperties = targetCatalog.properties.filter { foreign.contains($0.id.databaseText) }
            try readPages(targetRows, catalog: targetCatalog, properties: targetProperties, in: db)
            try readCells(targetRows, properties: targetProperties, catalog: targetCatalog, in: db)
        }
    }

    private mutating func readPages(_ rows: [UUID], catalog: DatabaseCatalog, properties: [DatabaseProperty], in db: Database) throws {
        let marks = Array(repeating: "?", count: rows.count).joined(separator: ",")
        let pageKinds = properties.filter { [.title, .createdTime, .lastEditedTime].contains($0.kind) }
        for row in try Row.fetchAll(db, sql: "SELECT id, title, createdAt, updatedAt, CAST(updatedAt AS TEXT) AS stamp FROM page WHERE id IN (\(marks))",
                                    arguments: StatementArguments(rows.map(\.databaseText))) {
            guard let id = UUID(uuidString: row["id"]) else { continue }
            stamps[id] = row["stamp"]
            titles[id] = row["title"]
            for property in pageKinds {
                let value: FormulaValue = switch property.kind {
                case .title: .text(row["title"])
                case .createdTime: .date(FormulaDate(start: row["createdAt"], hasTime: true))
                default: .date(FormulaDate(start: row["updatedAt"], hasTime: true))
                }
                values[id, default: [:]][property.id.databaseText] = value
            }
        }
    }

    private mutating func readCells(_ rows: [UUID], properties: [DatabaseProperty], catalog: DatabaseCatalog, in db: Database) throws {
        let stored = properties.filter { $0.kind.storesCells || $0.kind == .formula || $0.kind == .rollup }
        guard !stored.isEmpty else { return }
        let byId = Dictionary(uniqueKeysWithValues: stored.map { ($0.id.databaseText, $0) })
        let marks = Array(repeating: "?", count: rows.count).joined(separator: ",")
        let propertyMarks = Array(repeating: "?", count: stored.count).joined(separator: ",")
        for table in ["db_cell", "db_computed"] {
            let cursor = try Row.fetchCursor(db, sql: """
                SELECT rowId, propertyId, value FROM \(table) WHERE rowId IN (\(marks)) AND propertyId IN (\(propertyMarks)) AND value IS NOT NULL
                """, arguments: StatementArguments(rows.map(\.databaseText) + stored.map(\.id.databaseText)))
            while let row = try cursor.next() {
                guard let rowId = UUID(uuidString: row[0]), let property = byId[row[1]], let text: String = row[2],
                      let json = FastJSON.parse(text) else { continue }
                values[rowId, default: [:]][row[1]] = Self.formulaValue(json, property: property, catalog: catalog)
            }
        }
    }

    /// Значение свойства в формуле (contracts/formulas.md, «`prop` отдаёт»).
    static func formulaValue(_ json: JSONValue, property: DatabaseProperty, catalog: DatabaseCatalog) -> FormulaValue {
        switch property.kind {
        case .number, .uniqueId: return json.number.map(FormulaValue.number) ?? .empty
        case .checkbox: return .bool(json.bool ?? false)
        case .date: return date(json)
        case .select, .status:
            return json.string.flatMap(UUID.init(uuidString:)).flatMap { catalog.optionsById[$0]?.name }.map(FormulaValue.text) ?? .text("")
        case .multiSelect:
            return .list((json.array ?? []).compactMap { $0.string.flatMap(UUID.init(uuidString:)).flatMap { catalog.optionsById[$0]?.name } }
                .map(FormulaValue.text))
        case .files: return .list(FilesType.names(json).map(FormulaValue.text))
        case .text: return .text(TextType.string(json))
        case .formula, .rollup: return computed(json)
        default: return json.string.map(FormulaValue.text) ?? .empty
        }
    }

    static func date(_ json: JSONValue) -> FormulaValue {
        guard let start = DateValues.start(json) else { return .empty }
        return .date(FormulaDate(start: start, end: DateValues.end(json), hasTime: json["hasTime"]?.bool ?? false))
    }

    static func computed(_ json: JSONValue) -> FormulaValue {
        switch json {
        case .number(let number): .number(number)
        case .string(let text): .text(text)
        case .bool(let flag): .bool(flag)
        case .object: date(json)
        case .array(let items): .list(items.map(computed))
        default: .empty
        }
    }

    func value(ofProperty propertyId: String, row rowId: UUID) -> FormulaValue {
        values[rowId]?[propertyId] ?? .empty
    }

    func title(ofPage pageId: UUID) -> String? { titles[pageId] }

    /// Итог формулы — JSON для `db_computed`.
    static func json(_ value: FormulaValue, calendar: Calendar, titles: [UUID: String] = [:]) -> JSONValue? {
        switch value {
        case .empty: return nil
        case .number(let number): return number.isFinite ? .number(number) : nil
        case .text(let text): return .string(text)
        case .bool(let flag): return .bool(flag)
        case .date(let date):
            let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date.start)
            let day = String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
            return ["start": .string(date.hasTime ? day + String(format: "T%02d:%02d", c.hour!, c.minute!) : day), "hasTime": .bool(date.hasTime),
                    "timeZone": .string(calendar.timeZone.identifier)]
        case .list(let items): return .array(items.compactMap { json($0, calendar: calendar, titles: titles) })
        // Название — для показа плашкой, поиска и сортировки без чтения страницы.
        case .page(let id): return ["id": .string(id.databaseText), "title": .string(titles[id] ?? "")]
        }
    }
}
