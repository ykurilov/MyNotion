import ControlProtocol
import Databases
import Foundation
import NotesCore

/// Виды (T049): список, новый, имя, копия, удаление, порядок вкладок и все настройки вида по именам свойств и групп.
enum ViewHandlers {
    static let all: [String: CommandHandler] = [
        "db.view.list": { session in
            let database = try session.database()
            let views = try ViewQuery.views(of: database.page.id, in: session.host.store)
            return CommandResult(["views": .array(views.map { DatabaseJSON.view($0, catalog: database.catalog) })],
                                 text: views.map(\.name).joined(separator: "\n"))
        },
        "db.view.add": { session in
            let database = try session.database()
            let id = try session.databases.addView(to: database.page.id, name: session.string("name") ?? "Таблица")
            return try session.viewResult(id, of: database.page.id, "✓ Вид добавлен")
        },
        "db.view.rename": { session in
            let (database, view) = try session.databaseView()
            try session.databases.renameView(view.id, to: session.string("name") ?? "")
            return try session.viewResult(view.id, of: database.page.id, "✓ Вид переименован")
        },
        "db.view.duplicate": { session in
            let (database, view) = try session.databaseView()
            let copy = try session.databases.duplicateView(view.id)
            return try session.viewResult(copy, of: database.page.id, "✓ Копия вида «\(view.name)»")
        },
        "db.view.delete": { session in
            let (database, view) = try session.databaseView()
            guard try ViewQuery.views(of: database.page.id, in: session.host.store).count > 1 else {
                throw ControlError(.invalidValue, "Последний вид базы не удалить", hint: "Сначала: mynotion db view add", details: ["view": .string(view.name)])
            }
            try session.databases.deleteView(view.id)
            return CommandResult(["view": DatabaseJSON.view(view, catalog: database.catalog)], text: "✓ Вид «\(view.name)» удалён")
        },
        "db.view.move": { session in
            let (database, view) = try session.databaseView()
            var index = 0
            if let after = session.string("after") {
                let anchor = try session.databaseRefs.view(after, ofDatabase: database.page.id)
                let others = try ViewQuery.views(of: database.page.id, in: session.host.store).filter { $0.id != view.id }
                index = (others.firstIndex { $0.id == anchor.id } ?? -1) + 1
            }
            try session.databases.moveView(view.id, to: index)
            return try session.viewResult(view.id, of: database.page.id, "✓ Вид «\(view.name)» передвинут")
        },
        "db.view.update": update,
    ]

    static let update: CommandHandler = { session in
        let (database, view) = try session.databaseView()
        let catalog = database.catalog, operations = session.databases, refs = session.databaseRefs
        if let filter = session.args["filter"] { try operations.setFilter(try ViewJSON.filter(filter, in: catalog), of: view.id) }
        if let sort = session.args["sort"] { try operations.setSorts(try ViewJSON.sorts(sort, in: catalog), of: view.id) }
        if let group = session.args["group"] { try operations.setGroup(try ViewJSON.group(group, in: catalog), of: view.id) }
        for (key, isVisible) in [("visible", true), ("hidden", false)] {
            for name in session.strings(key) { try operations.setVisible(try refs.property(name, in: catalog).id, isVisible, in: view.id) }
        }
        for (index, name) in session.strings("order").enumerated() {
            try operations.moveColumn(try refs.property(name, in: catalog).id, in: view.id, to: index + 1)
        }
        for (property, width) in try session.assignments("width", in: catalog) {
            guard let pixels = Double(width), pixels > 0 else { throw ControlError.invalidChoice("width", width, allowed: ["имя=число пикселей"]) }
            try operations.setColumnWidth(property.id, in: view.id, to: pixels)
        }
        if let wrap = session.string("wrap") { try operations.setWrapAllContent(wrap == "on", in: view.id) }
        for (property, name) in try session.assignments("calc", in: catalog) {
            let allowed = PropertyTypes.type(for: property.kind).calculations
            if name == "none" {
                try operations.setCalculation(nil, of: property.id, in: view.id)
                continue
            }
            guard let calculation = Calculation(rawValue: name), allowed.contains(calculation) else {
                throw ControlError.invalidChoice("calc", name, allowed: ["none"] + allowed.map(\.rawValue))
            }
            try operations.setCalculation(calculation, of: property.id, in: view.id)
        }
        if let openIn = session.string("openIn") {
            try operations.setOpenRowsIn(["side": .sidePeek, "center": .centerPeek, "full": .fullPage][openIn] ?? .sidePeek, in: view.id)
        }
        if let limit = session.int("loadLimit") {
            guard ViewLayoutOptions.loadLimits.contains(limit) else {
                throw ControlError.invalidChoice("loadLimit", String(limit), allowed: ViewLayoutOptions.loadLimits.map(String.init))
            }
            try operations.setLoadLimit(limit, in: view.id)
        }
        try session.updateGroups(of: view.id)
        if let row = session.string("orderRows") { try session.orderRow(row, after: session.string("after"), in: view.id, of: database.page.id) }
        return try session.viewResult(view.id, of: database.page.id, "✓ Вид «\(view.name)» изменён")
    }
}

extension CommandSession {
    func databaseView() throws(ControlError) -> (ResolvedDatabase, DatabaseView) {
        let database = try database()
        return (database, try databaseRefs.view(string("view"), ofDatabase: database.page.id))
    }

    func viewResult(_ viewId: UUID, of databaseId: UUID, _ text: String) throws -> CommandResult {
        guard let view = try ViewQuery.views(of: databaseId, in: host.store).first(where: { $0.id == viewId }) else {
            throw NotesStoreError.invalidRecord("вида нет")
        }
        return CommandResult(["view": DatabaseJSON.view(view, catalog: try catalog(of: databaseId))], text: text)
    }

    /// Список `имя=значение` (ширина, итоги) со свойствами.
    func assignments(_ key: String, in catalog: DatabaseCatalog) throws(ControlError) -> [(DatabaseProperty, String)] {
        var result: [(DatabaseProperty, String)] = []
        for item in strings(key) {
            guard let equals = item.lastIndex(of: "=") else {
                throw ControlError(.invalidValue, "--\(key): «\(item)» — нужно имя=значение", hint: "Пример: --\(key) Часы=…",
                                   details: ["argument": .string(key)])
            }
            let property = try databaseRefs.property(String(item[..<equals]), in: catalog)
            result.append((property, String(item[item.index(after: equals)...]).trimmingCharacters(in: .whitespaces)))
        }
        return result
    }

    /// Скрыть, показать, свернуть, раскрыть группы и их порядок. Группа — по заголовку («Готово», «Нет «Статус»») или ключу.
    func updateGroups(of viewId: UUID) throws {
        let edits: [(String, (String, [String]) throws -> Void)] = [
            ("groupHide", { try self.databases.setGroupHidden($0, true, order: $1, in: viewId) }),
            ("groupShow", { try self.databases.setGroupHidden($0, false, order: $1, in: viewId) }),
            ("groupCollapse", { try self.databases.setGroupCollapsed($0, true, order: $1, in: viewId) }),
            ("groupExpand", { try self.databases.setGroupCollapsed($0, false, order: $1, in: viewId) }),
        ]
        for (key, edit) in edits {
            guard let name = string(key) else { continue }
            let groups = try currentGroups(of: viewId)
            try edit(try group(name, among: groups).key, groups.map(\.key))
        }
        for (index, name) in strings("groupOrder").enumerated() {
            let groups = try currentGroups(of: viewId)
            try databases.moveGroup(try group(name, among: groups).key, to: index, order: groups.map(\.key), in: viewId)
        }
    }

    private func currentGroups(of viewId: UUID) throws -> [ViewGroup] {
        guard let groups = try ViewQuery.present(viewId, in: host.store)?.groups else {
            throw ControlError(.invalidValue, "Вид не сгруппирован", hint: #"Сначала: --group '{"property":"Статус"}'"#,
                               details: ["argument": "group"])
        }
        return groups
    }

    private func group(_ name: String, among groups: [ViewGroup]) throws(ControlError) -> ViewGroup {
        let key = PagePath.normalized(name)
        if let group = groups.first(where: { $0.key == name }) ?? groups.first(where: { PagePath.normalized($0.label.title) == key }) {
            return group
        }
        throw ControlError(.invalidValue, "У вида нет группы «\(name)»", hint: "Группы: " + groups.map(\.label.title).joined(separator: ", "),
                           details: ["group": .string(name), "allowed": .array(groups.map { .string($0.label.title) })])
    }

    /// Ручной порядок строк вида: строка встаёт за `after` (без него — первой).
    func orderRow(_ pointer: String, after: String?, in viewId: UUID, of databaseId: UUID) throws {
        let row = try databaseRefs.row(pointer, inDatabase: databaseId)
        let previous = try after.map { text throws(ControlError) in try databaseRefs.row(text, inDatabase: databaseId).id }
        let order = (try ViewQuery.present(viewId, in: host.store)?.rowIds ?? []).filter { $0 != row.id }
        let next = previous.map { id in order.firstIndex(of: id).flatMap { $0 + 1 < order.count ? order[$0 + 1] : nil } } ?? order.first
        try databases.moveRows([row.id], in: viewId, between: previous, and: next)
    }
}
