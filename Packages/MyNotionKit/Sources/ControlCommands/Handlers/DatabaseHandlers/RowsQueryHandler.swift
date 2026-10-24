import ControlProtocol
import Databases
import Foundation
import NotesCore

/// `db rows` (T049): строки в порядке и группах вида, как их показывает таблица (`ViewQuery`). `--filter`, `--sort` и
/// `--search` действуют на один ответ и в вид не пишутся. Части — по сплошному списку строк всех показанных групп.
enum RowsQueryHandler {
    static let all: [String: CommandHandler] = ["db.rows": rows]

    static let rows: CommandHandler = { session in
        let database = try session.database()
        let catalog = database.catalog
        var view = try session.databaseRefs.view(session.string("view"), ofDatabase: database.page.id)
        let savedViewId = view.id
        if let filter = session.args["filter"] { view.filter = try ViewJSON.filter(filter, in: catalog)?.json }
        if let sort = session.args["sort"] { view.sorts = .array(try ViewJSON.sorts(sort, in: catalog).map(\.json)) }
        let search = session.string("search").flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        var properties: [DatabaseProperty] = []
        for name in session.strings("properties") { properties.append(try session.databaseRefs.property(name, in: catalog)) }
        if session.args["properties"] == nil {
            properties = ViewQuery.visiblePropertyIds(of: view, catalog: catalog).compactMap { catalog.propertiesById[$0] }
        }

        let queried = view
        let presented = try session.host.store.database.dbWriter.read { db in
            try ViewQuery.present(queried, catalog: catalog, search: search, in: db)
        }
        let groups = presented.groups.map { ViewGrouping.shown($0, hideEmpty: view.groupSettings?.hideEmpty ?? true) }
        // Сплошной список (группа, строка): курсор — смещение в нём.
        var entries: [(group: Int, row: UUID)] = []
        if let groups {
            for (index, group) in groups.enumerated() { entries += group.rowIds.map { (index, $0) } }
        } else {
            entries = presented.rowIds.map { (0, $0) }
        }
        let paged = try session.paged(entries.indices.map { .number(Double($0)) })
        let window = (paged["items"]?.array ?? []).compactMap { $0.int }.map { entries[$0] }
        let snapshots = try RowWindowReader.read(window.map(\.row), catalog: catalog, store: session.host.store)
        let context = session.cellContext(catalog)

        var result: [ControlJSON] = []
        var current: (group: Int, rows: [ControlJSON])?
        func flush() {
            guard let current else { return }
            let group = groups?[current.group]
            result.append([
                "key": group.map { .string($0.label.title) } ?? .null, "id": group.map { .string($0.key) } ?? .null,
                "count": .number(Double(group?.rowIds.count ?? presented.rowIds.count)), "collapsed": .bool(group?.isCollapsed ?? false),
                "rows": .array(current.rows),
            ])
        }
        for entry in window {
            guard let snapshot = snapshots[entry.row] else { continue }
            if current?.group != entry.group {
                flush()
                current = (entry.group, [])
            }
            current?.rows.append(DatabaseJSON.row(snapshot, properties: properties, in: context))
        }
        flush()

        let data: ControlJSON = ["view": .string(savedViewId.controlText), "groups": .array(result), "total": .number(Double(entries.count)),
                                 "nextCursor": paged["nextCursor"] ?? .null]
        let titles = window.compactMap { snapshots[$0.row]?.title }
        return CommandResult(data, text: (["Строк: \(entries.count)"] + titles.map { "  " + ($0.isEmpty ? Page.untitledTitle : $0) })
            .joined(separator: "\n"))
    }
}
