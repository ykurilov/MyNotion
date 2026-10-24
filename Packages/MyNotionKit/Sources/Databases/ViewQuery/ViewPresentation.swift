import Foundation
import GRDB
import NotesCore

/// Что показывает вид (US3): строки после фильтра, поиска и сортировок, а у сгруппированного вида — ещё и группы.
public struct ViewPresentation: Sendable {
    public var catalog: DatabaseCatalog
    public var view: DatabaseView
    /// Все подходящие строки по порядку сортировок (без групп).
    public var rowIds: [UUID]
    /// Все группы вида (и скрытые, и пустые); `nil` — вид не сгруппирован или свойства группы нет.
    public var groups: [ViewGroup]?
}

extension ViewQuery {
    /// Открыть вид целиком одним чтением: запрос SQL (фильтр, поиск, сортировки), затем группы по значениям строк.
    public static func present(_ viewId: UUID, in store: NotesStore, search: String? = nil, now: Date = Date()) throws -> ViewPresentation? {
        try store.database.dbWriter.read { db in
            guard let view = try Row.fetchOne(db, sql: "SELECT * FROM db_view WHERE id = ?", arguments: [viewId.databaseText])
                .map(DatabaseView.init(row:)) else { return nil }
            let catalog = try DatabaseCatalog.read(view.databaseId, in: db)
            return try present(view, catalog: catalog, search: search, now: now, in: db)
        }
    }

    public static func present(_ view: DatabaseView, catalog: DatabaseCatalog, search: String?, now: Date = Date(), in db: Database) throws -> ViewPresentation {
        var spec = ViewQuerySpec(view: view, search: search)
        // Группы считаются по значениям (у множественного выбора строка — в каждой своей группе): SQL их не упорядочивает.
        spec.groupPropertyId = nil
        if search != nil { spec.searchPropertyIds = visiblePropertyIds(of: view, catalog: catalog) }
        var query = ViewQuerySQL(spec: spec, catalog: catalog, now: now)
        guard let settings = view.groupSettings, let property = catalog.propertiesById[settings.propertyId],
              PropertyTypes.type(for: property.kind).isGroupable else {
            return ViewPresentation(catalog: catalog, view: view, rowIds: try query.fetch(in: db).rowIds, groups: nil)
        }
        let context = catalog.context(for: property)
        let rowIds: [UUID], values: [UUID: JSONValue]
        if property.kind == .select || property.kind == .status {
            // Вариант — тем же запросом и только у найденных строк (профиль T085: 10 000 значений ради 1 600 строк).
            (rowIds, values) = try query.fetch(in: db, optionValuesOf: property)
        } else {
            rowIds = try query.fetch(in: db).rowIds
            values = try PropertyValues.read(property, of: catalog.databaseId, context: context, in: db)
        }
        let groups = ViewGrouping.groups(rowIds: rowIds, values: values, settings: settings, context: context)
        return ViewPresentation(catalog: catalog, view: view, rowIds: rowIds, groups: groups)
    }
}
