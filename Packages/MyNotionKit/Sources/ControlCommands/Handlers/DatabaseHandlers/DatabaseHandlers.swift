import ControlProtocol
import Databases
import Formulas
import Foundation
import GRDB
import NotesCore

/// Базы — этап 4 005 (US3): схема, строки и ячейки, виды, шаблоны строк (004, US6), строки по виду.
public enum DatabaseHandlers {
    public static let all: [String: CommandHandler] = SchemaHandlers.all
        .merging(RowHandlers.all) { first, _ in first }
        .merging(ViewHandlers.all) { first, _ in first }
        .merging(TemplateHandlers.all) { first, _ in first }
        .merging(RowsQueryHandler.all) { first, _ in first }
}

/// Свойства, варианты, виды и строки в ответах команд баз (contracts/commands.md, «db»).
enum DatabaseJSON {
    static func property(_ property: DatabaseProperty, catalog: DatabaseCatalog, formulas: DatabaseFormulaSchema? = nil) -> ControlJSON {
        var object: [String: ControlJSON] = [
            "id": .string(property.id.controlText), "name": .string(property.name), "type": .string(property.kind.rawValue),
            "config": property.config.control,
        ]
        if [.select, .multiSelect, .status].contains(property.kind) {
            object["options"] = .array((catalog.options[property.id] ?? []).map(option))
        }
        if property.kind == .formula, let formulas {
            object["formula"] = .string(FormulaSource.display(property.config["expression"]?.string ?? "", schema: formulas))
        }
        return .object(object)
    }

    static func option(_ option: SelectOption) -> ControlJSON {
        ["id": .string(option.id.controlText), "name": .string(option.name), "color": .string(option.color),
         "group": option.statusGroup.map { .string($0.rawValue) } ?? .null]
    }

    static func view(_ view: DatabaseView, catalog: DatabaseCatalog) -> ControlJSON {
        let visible = ViewQuery.visiblePropertyIds(of: view, catalog: catalog)
        let layout = view.layout
        let columns: [ControlJSON] = catalog.properties.map { property in
            let column = view.column(property.id)
            return ["property": .string(property.name), "visible": .bool(visible.contains(property.id)),
                    "width": column?["width"]?.control ?? .null, "wrap": .bool(view.wraps(property.id)),
                    "calc": view.calculation(of: property.id).map { .string($0.rawValue) } ?? .null]
        }
        return [
            "id": .string(view.id.controlText), "name": .string(view.name), "type": .string(view.type),
            "filter": view.filterNode.map { ViewJSON.encode($0, in: catalog) } ?? .null,
            "sort": ViewJSON.encode(view.sortSpecs, in: catalog),
            "group": view.groupSettings.map { ViewJSON.encode($0, in: catalog) } ?? .null,
            "properties": .array(visible.compactMap { catalog.propertiesById[$0].map { .string($0.name) } }),
            "columns": .array(columns),
            "openIn": .string(layout.openRowsIn.rawValue), "loadLimit": .number(Double(layout.loadLimit)),
            "wrap": .bool(layout.wrapAllContent),
        ]
    }

    /// Строка: id, название и значения по именам свойств (без «Названия»). Вычисляемые — `{value, display}`, связь —
    /// `[{id, title}]`.
    static func row(_ snapshot: RowSnapshot, properties: [DatabaseProperty], in context: CellContext) -> ControlJSON {
        var values: [String: ControlJSON] = [:]
        for property in properties where property.kind != .title {
            values[property.name] = value(of: property, in: snapshot, context: context)
        }
        return ["id": .string(snapshot.id.controlText), "title": .string(snapshot.title), "values": .object(values)]
    }

    private static func value(of property: DatabaseProperty, in snapshot: RowSnapshot, context: CellContext) -> ControlJSON {
        switch property.kind {
        case .relation:
            return .array((snapshot.relations[property.id] ?? []).map { ["id": .string($0.id.controlText), "title": .string($0.title)] })
        case .createdTime:
            return .string(snapshot.createdAt.controlText)
        case .lastEditedTime:
            return .string(snapshot.updatedAt.controlText)
        case .formula, .rollup, .uniqueId:
            guard let value = snapshot.computed[property.id] ?? snapshot.cells[property.id] else { return .null }
            let display = CellPresenter.present(property, in: snapshot, context: context.catalog.context(for: property)).plainText
            return ["value": value.control, "display": .string(display.isEmpty ? PropertyTypes.type(for: property.kind)
                    .displayText(value, in: context.catalog.context(for: property)) : display)]
        default:
            return snapshot.cells[property.id].map { CellValueJSON.encode($0, of: property, in: context) } ?? .null
        }
    }
}

extension CommandSession {
    /// Кодек ячеек базы: календарь Mac, вложения и названия упоминаний из хранилища.
    func cellContext(_ catalog: DatabaseCatalog) -> CellContext {
        let store = host.store, attachments = host.attachments
        return CellContext(catalog: catalog, attachments: { id in (try? attachments.record(id))??.ref },
                           titles: { id in (try? store.page(id))?.map { ($0.title, $0.icon) } })
    }

    /// Свойства и варианты базы заново (после правки схемы).
    func catalog(of databaseId: UUID) throws -> DatabaseCatalog {
        try DatabaseCatalog.read(databaseId, in: host.store)
    }

    /// Строки по id в ответе: значения `properties` (по умолчанию — все свойства базы).
    func rowsJSON(_ rowIds: [UUID], databaseId: UUID, properties: [DatabaseProperty]? = nil) throws -> [ControlJSON] {
        let catalog = try catalog(of: databaseId)
        let snapshots = try RowWindowReader.read(rowIds, catalog: catalog, store: host.store)
        let context = cellContext(catalog)
        return rowIds.compactMap { id in snapshots[id].map { DatabaseJSON.row($0, properties: properties ?? catalog.properties, in: context) } }
    }

    /// Страница базы в ответе (`kind: database`).
    func databasePageJSON(_ databaseId: UUID) throws -> ControlJSON {
        let index = try PageQueries.chain(of: databaseId, in: host.store)
        guard let page = index.byId[databaseId] else { throw NotesStoreError.pageNotFound(databaseId) }
        let path = (index.ancestors(of: page) + [page]).map(\.displayTitle)
        return PageJSON.encode(page, kind: .database, path: path, hasChildren: try PageQueries.hasChildren(databaseId, in: host.store),
                               inTrash: index.isInTrash(page))
    }

    /// Живые строки базы (без корзины и шаблонов) — сколько их.
    func rowCount(of databaseId: UUID) throws -> Int {
        try host.store.database.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM page WHERE parentId = ? AND trashedAt IS NULL AND isTemplate = 0",
                             arguments: [databaseId.databaseText]) ?? 0
        }
    }
}

extension ControlError {
    /// Та же ошибка с полем `details.<key>` (номер строки пачки и т. п.).
    func adding(_ key: String, _ value: ControlJSON) -> ControlError {
        var copy = self
        var object = details?.object ?? [:]
        object[key] = value
        copy.details = .object(object)
        return copy
    }

    static func invalidChoice(_ argument: String, _ value: String, allowed: [String]) -> ControlError {
        ControlError(.invalidValue, "«\(value)» не подходит для \(argument)", hint: "Подходят: " + allowed.joined(separator: ", "),
                     details: ["argument": .string(argument), "allowed": .array(allowed.map(ControlJSON.string))])
    }
}
