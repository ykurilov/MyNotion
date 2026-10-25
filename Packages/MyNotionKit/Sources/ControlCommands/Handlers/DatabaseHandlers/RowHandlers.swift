import ControlProtocol
import Databases
import Foundation
import NotesCore

/// Строки и ячейки (T048): одна строка и пачка до 1 000 одним шагом, правка значений, корзина, копии, связи.
/// Значения разбираются до записи: ошибка в любой строке пачки не пишет ничего (`details.row` — её номер с нуля).
enum RowHandlers {
    static let batchLimit = 1_000

    static let all: [String: CommandHandler] = [
        "db.row.add": addRows,
        "db.row.update": { session in
            let database = try session.database()
            let row = try session.databaseRefs.row(session.string("row") ?? "", inDatabase: database.page.id)
            let writer = RowValuesWriter(session: session, database: database)
            try writer.write([try writer.parse(session.args["values"] ?? [:])], to: [row.id])
            return try session.rowResult(row.id, of: database.page.id, "✓ Строка «\(row.displayTitle)» изменена")
        },
        "db.cell.set": { session in
            let database = try session.database()
            let row = try session.databaseRefs.row(session.string("row") ?? "", inDatabase: database.page.id)
            let property = try session.databaseRefs.property(session.string("property") ?? "", in: database.catalog)
            let writer = RowValuesWriter(session: session, database: database)
            try writer.write([try writer.parse([(property, session.args["value"] ?? .null)])], to: [row.id])
            return try session.rowResult(row.id, of: database.page.id, "✓ «\(property.name)» у «\(row.displayTitle)»")
        },
        "db.row.trash": { session in
            let (database, rows) = try session.databaseRows(includeTrashed: false)
            try session.databases.setRowsTrashed(rows.map(\.id), true)
            return CommandResult(["rows": .array(try session.rowsJSON(rows.map(\.id), databaseId: database.page.id))],
                                 text: "✓ В корзине строк: \(rows.count)")
        },
        "db.row.restore": { session in
            let (database, rows) = try session.databaseRows(includeTrashed: true)
            try session.databases.setRowsTrashed(rows.map(\.id), false)
            return CommandResult(["rows": .array(try session.rowsJSON(rows.map(\.id), databaseId: database.page.id))],
                                 text: "✓ Возвращено строк: \(rows.count)")
        },
        "db.row.duplicate": { session in
            let (database, rows) = try session.databaseRows(includeTrashed: false)
            let copies = try session.databases.duplicateRows(rows.map(\.id), in: nil)
            session.touch(Set(copies))
            return CommandResult(["rows": .array(try session.rowsJSON(copies, databaseId: database.page.id))], text: "✓ Копий строк: \(copies.count)")
        },
        "db.relation.link": { session in try relation(session, linking: true) },
        "db.relation.unlink": { session in try relation(session, linking: false) },
    ]

    static let addRows: CommandHandler = { session in
        let database = try session.database()
        if session.string("template") != nil {
            throw ControlError(.notImplemented, "Шаблоны строк ещё не готовы", hint: "Без --template", details: ["argument": "template"])
        }
        let batch = session.args["rows"]
        let items: [ControlJSON]
        if let batch {
            guard let array = batch.array else {
                throw ControlError(.invalidValue, "--rows — массив объектов значений", hint: #"Пример: [{"Название":"Отчёт"}]"#,
                                   details: ["argument": "rows"])
            }
            guard array.count <= batchLimit else {
                throw ControlError(.invalidValue, "В пачке \(array.count) строк, можно до \(batchLimit)", hint: "Разбейте на части",
                                   details: ["argument": "rows", "limit": .number(Double(batchLimit))])
            }
            items = array
        } else {
            items = [session.args["values"] ?? [:]]
        }
        let writer = RowValuesWriter(session: session, database: database)
        var inputs: [RowInput] = []
        for (index, item) in items.enumerated() {
            do {
                inputs.append(try writer.parse(item))
            } catch let error as ControlError {
                throw batch == nil ? error : error.adding("row", .number(Double(index)))
            }
        }
        let ids = try writer.write(inputs, to: nil)
        session.touch(Set(ids))
        let rows = try session.rowsJSON(ids, databaseId: database.page.id)
        var data: [String: ControlJSON] = ["rows": .array(rows), "count": .number(Double(ids.count))]
        if batch == nil { data["row"] = rows.first ?? .null }
        return CommandResult(.object(data), text: "✓ Строк добавлено: \(ids.count)")
    }

    @MainActor private static func relation(_ session: CommandSession, linking: Bool) throws -> CommandResult {
        let database = try session.database()
        let row = try session.databaseRefs.row(session.string("row") ?? "", inDatabase: database.page.id)
        let property = try session.databaseRefs.property(session.string("property") ?? "", in: database.catalog)
        let targets = try RowValuesWriter(session: session, database: database).targetRows(session.strings("to"), of: property)
        for target in targets {
            if linking {
                try session.databases.linkRow(row.id, through: property.id, to: target)
            } else {
                try session.databases.unlinkRow(row.id, through: property.id, from: target)
            }
        }
        return try session.rowResult(row.id, of: database.page.id,
                                     linking ? "✓ «\(row.displayTitle)» связана: \(targets.count)" : "✓ Связей убрано: \(targets.count)")
    }
}

/// Значения одной строки до записи: ячейки по свойствам и связи — id строк цели.
struct RowInput {
    var cells: [(property: DatabaseProperty, input: CellInput)] = []
    var relations: [(property: DatabaseProperty, rowIds: [UUID])] = []
}

/// Разбор значений по именам свойств и запись одной правкой: недостающие варианты выбора создаются
/// (`warnings: option_created`), значения пишутся одним `writeCells`, связи — после.
@MainActor
struct RowValuesWriter {
    let session: CommandSession
    let database: ResolvedDatabase
    let context: CellContext

    init(session: CommandSession, database: ResolvedDatabase) {
        self.session = session
        self.database = database
        context = session.cellContext(database.catalog)
    }

    /// Объект `{"Имя свойства": значение}`.
    func parse(_ values: ControlJSON) throws(ControlError) -> RowInput {
        guard let object = values.object else {
            throw ControlError(.invalidValue, "Значения строки — объект {\"Свойство\": значение}", hint: #"Пример: {"Название":"Отчёт"}"#,
                               details: ["argument": "values"])
        }
        var pairs: [(DatabaseProperty, ControlJSON)] = []
        for (name, value) in object.sorted(by: { $0.key < $1.key }) {
            pairs.append((try session.databaseRefs.property(name, in: database.catalog), value))
        }
        return try parse(pairs)
    }

    func parse(_ pairs: [(DatabaseProperty, ControlJSON)]) throws(ControlError) -> RowInput {
        var input = RowInput()
        for (property, value) in pairs {
            switch try CellValueJSON.decode(value, for: property, in: context) {
            case .relation(let pointers): input.relations.append((property, try targetRows(pointers, of: property)))
            case .clear where property.kind == .relation: input.relations.append((property, []))
            case let cell: input.cells.append((property, cell))
            }
        }
        return input
    }

    /// Строки базы-цели связи по id или названиям.
    func targetRows(_ pointers: [String], of property: DatabaseProperty) throws(ControlError) -> [UUID] {
        guard property.kind == .relation, let target = property.relationTarget else {
            throw ControlError(.invalidValue, "«\(property.name)» — не связь", details: ["property": .string(property.name),
                                                                                         "type": .string(property.kind.rawValue)])
        }
        var ids: [UUID] = []
        for pointer in pointers {
            let id = try session.databaseRefs.row(pointer, inDatabase: target).id
            if !ids.contains(id) { ids.append(id) }
        }
        if property.relationLimit == .one, ids.count > 1 {
            throw ControlError(.invalidValue, "«\(property.name)» связывает одну строку, а не \(ids.count)",
                               details: ["property": .string(property.name), "limit": "one"])
        }
        return ids
    }

    /// Записать строки: `rowIds == nil` — новые строки пачкой, иначе — существующие по порядку. Возвращает id строк.
    @discardableResult
    func write(_ inputs: [RowInput], to rowIds: [UUID]?) throws -> [UUID] {
        let created = try createMissingOptions(inputs)
        var writes: [CellWrite] = []
        for (index, input) in inputs.enumerated() {
            let target: CellRowTarget = rowIds.map { .existing($0[index]) } ?? .appended(index)
            for (property, cell) in input.cells {
                writes.append(CellWrite(row: target, propertyId: property.id, value: value(cell, of: property, created: created)))
            }
        }
        let appended = try session.databases.writeCells(writes, appendingRows: rowIds == nil ? inputs.count : 0, to: database.page.id, in: nil)
        let ids = rowIds ?? appended
        for (index, input) in inputs.enumerated() {
            for (property, targets) in input.relations {
                let current = try RelationLinks.related(ids[index], through: property, in: session.host.store).map(\.id)
                for target in current where !targets.contains(target) {
                    try session.databases.unlinkRow(ids[index], through: property.id, from: target)
                }
                for target in targets where !current.contains(target) {
                    try session.databases.linkRow(ids[index], through: property.id, to: target)
                }
            }
        }
        return ids
    }

    /// Варианты, которых нет в базе: по одному на имя и свойство на всю пачку.
    private func createMissingOptions(_ inputs: [RowInput]) throws -> [UUID: [String: UUID]] {
        var created: [UUID: [String: UUID]] = [:]
        for input in inputs {
            for (property, cell) in input.cells {
                guard case .newOptions(_, let missing) = cell else { continue }
                for name in missing where created[property.id]?[PagePath.normalized(name)] == nil {
                    let option = try session.databases.createOption(in: property.id, named: name)
                    created[property.id, default: [:]][PagePath.normalized(name)] = option.id
                    session.warn(.optionCreated, "Новый вариант «\(name)» у «\(property.name)»")
                }
            }
        }
        return created
    }

    private func value(_ cell: CellInput, of property: DatabaseProperty, created: [UUID: [String: UUID]]) -> JSONValue? {
        switch cell {
        case .value(let value): return value
        case .clear: return nil
        case .title(let title): return .string(title)
        case .relation: return nil
        case .newOptions(let existing, let missing):
            let ids = existing + missing.compactMap { created[property.id]?[PagePath.normalized($0)] }
            if property.kind == .multiSelect { return .array(ids.map { .string($0.controlText) }) }
            return ids.first.map { .string($0.controlText) }
        }
    }
}

extension CommandSession {
    func rowResult(_ rowId: UUID, of databaseId: UUID, _ text: String) throws -> CommandResult {
        CommandResult(["row": try rowsJSON([rowId], databaseId: databaseId).first ?? .null], text: text)
    }

    /// База и строки из повторяемого аргумента `rows`.
    func databaseRows(includeTrashed: Bool) throws(ControlError) -> (ResolvedDatabase, [Page]) {
        let database = try database()
        var rows: [Page] = []
        for pointer in strings("rows") {
            let row = try databaseRefs.row(pointer, inDatabase: database.page.id, includeTrashed: includeTrashed)
            if !rows.contains(where: { $0.id == row.id }) { rows.append(row) }
        }
        guard !rows.isEmpty else { throw CommandCatalog.missing(named: "rows", in: spec) }
        return (database, rows)
    }
}
