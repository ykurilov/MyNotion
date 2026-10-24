import ControlProtocol
import Databases
import Foundation
import Testing
@testable import ControlCommands
@testable import NotesCore

/// Виды и чтение строк командами (T046): виды, настройки вида по именам, `db rows` в порядке и группах вида, разовые
/// фильтр, сортировка и поиск, части по курсору.
@MainActor @Suite struct ViewCommandsTests {
    let fixture: DatabaseCommandFixture
    let tasks: UUID

    init() async throws {
        fixture = try DatabaseCommandFixture()
        tasks = try await fixture.createDatabase()
        for (name, type) in [("Часы", "number"), ("Статус", "select"), ("Теги", "multiSelect"), ("Срок", "date")] {
            try await fixture.ok("db.prop.add", ["database": "Задачи", "name": .string(name), "type": .string(type)])
        }
        try await fixture.ok("db.row.add", ["database": "Задачи", "rows": [
            ["Название": "Отчёт", "Часы": 3, "Статус": "В работе", "Теги": ["Срочно"]],
            ["Название": "Звонок", "Часы": 1, "Статус": "Готово"],
            ["Название": "Сайт", "Часы": 8, "Статус": "В работе", "Теги": ["Дом"]],
            ["Название": "Счёт", "Часы": 2],
        ]])
    }

    func view(_ name: String) throws -> DatabaseView {
        try #require(try fixture.views(tasks).first { $0.name == name })
    }

    // MARK: Виды

    @Test func addsRenamesDuplicatesMovesDeletesAndListsViews() async throws {
        let added = try await fixture.ok("db.view.add", ["database": "Задачи", "name": "Срочные"])
        #expect(added["view"]?["name"] == "Срочные")
        try await fixture.ok("db.view.rename", ["database": "Задачи", "view": "Таблица", "name": "Все"])
        try await fixture.ok("db.view.duplicate", ["database": "Задачи", "view": "Все"])
        #expect(try fixture.views(tasks).map(\.name) == ["Все", "Все (1)", "Срочные"])
        try await fixture.ok("db.view.move", ["database": "Задачи", "view": "Срочные", "first": true])
        try await fixture.ok("db.view.move", ["database": "Задачи", "view": "Все (1)", "after": "Срочные"])
        #expect(try fixture.views(tasks).map(\.name) == ["Срочные", "Все (1)", "Все"])
        try await fixture.ok("db.view.delete", ["database": "Задачи", "view": "Все (1)"])
        let list = try await fixture.ok("db.view.list", ["database": "Задачи"])
        #expect(list["views"]?.array?.compactMap { $0["name"]?.string } == ["Срочные", "Все"])
        let missing = try await fixture.failure("db.view.rename", ["database": "Задачи", "view": "Нет", "name": "X"])
        #expect(missing.code == .viewNotFound)
    }

    @Test func updatesViewSettingsByNames() async throws {
        let filter: ControlJSON = ["and": [
            ["property": "Статус", "operator": "isNot", "value": "Готово"],
            ["or": [["property": "Часы", "operator": "greaterThan", "value": 2], ["property": "Теги", "operator": "contains", "value": "Срочно"]]],
        ]]
        let data = try await fixture.ok("db.view.update", [
            "database": "Задачи", "view": "Таблица", "filter": filter, "sort": [["property": "Часы", "direction": "descending"]],
            "group": ["property": "Статус", "sort": "manual", "hideEmpty": false], "hidden": ["Теги"], "order": ["Часы", "Статус"],
            "width": ["Часы=140"], "wrap": "on", "calc": ["Часы=sum"], "openIn": "center", "loadLimit": 25,
        ])
        let view = try view("Таблица")
        let hours = try fixture.property("Часы", in: tasks), status = try fixture.property("Статус", in: tasks)
        let tags = try fixture.property("Теги", in: tasks)
        let conditions = try #require(view.filterNode?.conditions)
        #expect(conditions.map(\.propertyId) == [status.id, hours.id, tags.id])
        guard case .and(let items)? = view.filterNode, case .or? = items.last else {
            Issue.record("фильтр не «И» с вложенной группой «ИЛИ»: \(String(describing: view.filterNode))")
            return
        }
        #expect(view.sortSpecs == [SortSpec(propertyId: hours.id, ascending: false)])
        #expect(view.groupSettings?.propertyId == status.id)
        #expect(view.groupSettings?.hideEmpty == false)
        #expect(!ViewQuery.visiblePropertyIds(of: view, catalog: try fixture.catalog(tasks)).contains(tags.id))
        let visible = ViewQuery.visiblePropertyIds(of: view, catalog: try fixture.catalog(tasks))
        #expect(Array(visible.prefix(3)) == [try fixture.property("Название", in: tasks).id, hours.id, status.id])
        #expect(view.column(hours.id)?["width"] == 140)
        #expect(view.layout.wrapAllContent)
        #expect(view.calculation(of: hours.id) == .sum)
        #expect(view.layout.openRowsIn == .centerPeek)
        #expect(view.layout.loadLimit == 25)
        #expect(data["view"]?["filter"]?["and"]?[0]?["property"] == "Статус")
        #expect(data["view"]?["filter"]?["and"]?[0]?["value"] == "Готово")
        #expect(data["view"]?["group"]?["property"] == "Статус")

        try await fixture.ok("db.view.update", ["database": "Задачи", "view": "Таблица", "groupHide": "Готово", "groupCollapse": "В работе",
                                                "groupOrder": ["В работе", "Нет «Статус»"]])
        let grouped = try #require(try self.view("Таблица").groupSettings)
        let working = try #require(try fixture.catalog(tasks).options[status.id]?.first { $0.name == "В работе" })
        let done = try #require(try fixture.catalog(tasks).options[status.id]?.first { $0.name == "Готово" })
        #expect(grouped.state(of: done.id.databaseText).isHidden)
        #expect(grouped.state(of: working.id.databaseText).isCollapsed)
        #expect(Array(grouped.groups.map(\.key).prefix(2)) == [working.id.databaseText, GroupSettings.emptyKey])
        try await fixture.ok("db.view.update", ["database": "Задачи", "view": "Таблица", "groupShow": "Готово", "groupExpand": "В работе"])
        #expect(try self.view("Таблица").groupSettings?.state(of: done.id.databaseText).isHidden == false)

        try await fixture.ok("db.view.update", ["database": "Задачи", "view": "Таблица", "filter": .null, "group": .null, "sort": .null,
                                                "visible": ["Теги"]])
        #expect(try self.view("Таблица").filterNode == nil)
        #expect(try self.view("Таблица").groupSettings == nil)
        #expect(ViewQuery.visiblePropertyIds(of: try self.view("Таблица"), catalog: try fixture.catalog(tasks)).contains(tags.id))
    }

    @Test func ordersRowsManuallyInView() async throws {
        try await fixture.ok("db.view.update", ["database": "Задачи", "view": "Таблица", "orderRows": "Счёт", "after": "Отчёт"])
        let rows = try await fixture.ok("db.rows", ["database": "Задачи"])
        #expect(DatabaseCommandFixture.rowTitles(rows) == ["Отчёт", "Счёт", "Звонок", "Сайт"])
    }

    @Test func rejectsOperatorThatDoesNotFitType() async throws {
        let error = try await fixture.failure("db.view.update", ["database": "Задачи", "view": "Таблица",
                                                                 "filter": ["property": "Часы", "operator": "contains", "value": 1]])
        #expect(error.code == .invalidValue)
        #expect(error.details?["allowed"]?.array?.contains("greaterThan") == true)
        #expect(try view("Таблица").filterNode == nil)
    }

    // MARK: Строки

    @Test func rowsFollowViewOrderAndGroups() async throws {
        try await fixture.ok("db.view.update", ["database": "Задачи", "view": "Таблица", "sort": [["property": "Часы", "direction": "ascending"]],
                                                "group": ["property": "Статус", "hideEmpty": true]])
        let data = try await fixture.ok("db.rows", ["database": "Задачи", "view": "Таблица"])
        let presented = try #require(try ViewQuery.present(try view("Таблица").id, in: fixture.store))
        let shown = ViewGrouping.shown(try #require(presented.groups), hideEmpty: true)
        let groups = try #require(data["groups"]?.array)
        #expect(groups.count == shown.count)
        for (group, expected) in zip(groups, shown) {
            #expect(group["key"] == .string(expected.label.title))
            #expect(group["count"] == .number(Double(expected.rowIds.count)))
            #expect(group["rows"]?.array?.compactMap { $0["id"]?.string } == expected.rowIds.map(\.controlText))
        }
        #expect(groups.first?["key"] == "Нет «Статус»")
        let inProgress = try #require(groups.first { $0["key"] == "В работе" })
        #expect(inProgress["rows"]?.array?.compactMap { $0["title"]?.string } == ["Отчёт", "Сайт"])
        #expect(inProgress["rows"]?[0]?["values"]?["Часы"] == 3)
        #expect(data["view"] == .string(try view("Таблица").id.controlText))
    }

    @Test func oneOffFilterSortAndSearchAreNotSaved() async throws {
        let filtered = try await fixture.ok("db.rows", ["database": "Задачи", "filter": ["property": "Статус", "operator": "is", "value": "В работе"],
                                                        "sort": [["property": "Часы", "direction": "descending"]], "properties": ["Часы"]])
        #expect(DatabaseCommandFixture.rowTitles(filtered) == ["Сайт", "Отчёт"])
        #expect(filtered["groups"]?[0]?["rows"]?[0]?["values"]?.object?.keys.sorted() == ["Часы"])
        let searched = try await fixture.ok("db.rows", ["database": "Задачи", "search": "звон"])
        #expect(DatabaseCommandFixture.rowTitles(searched) == ["Звонок"])
        #expect(try view("Таблица").filterNode == nil)
        #expect(try view("Таблица").sortSpecs.isEmpty)
    }

    @Test func pagesThroughTenThousandRows() async throws {
        let big = try await fixture.createDatabase("Большая")
        let operations = DatabaseOperations(store: fixture.store)
        let title = try #require(try fixture.catalog(big).titleProperty)
        let writes = (0..<10_000).map { CellWrite(row: .appended($0), propertyId: title.id, value: .string(String(format: "Р%05d", $0))) }
        try operations.writeCells(writes, appendingRows: 10_000, to: big, in: nil)
        var seen: [String] = []
        var cursor: ControlJSON?
        var pages = 0
        repeat {
            var args: [String: ControlJSON] = ["database": "Проекты/Большая", "limit": 1_000]
            if let cursor { args["cursor"] = cursor }
            let data = try await fixture.ok("db.rows", args)
            seen += DatabaseCommandFixture.rowTitles(data)
            cursor = data["nextCursor"]?.string.map(ControlJSON.string)
            pages += 1
        } while cursor != nil && pages < 20
        #expect(pages == 10)
        #expect(seen.count == 10_000)
        #expect(seen.first == "Р00000")
        #expect(seen.last == "Р09999")
        #expect(Set(seen).count == 10_000)
    }
}
