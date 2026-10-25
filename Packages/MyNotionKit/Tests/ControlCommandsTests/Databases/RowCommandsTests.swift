import ControlProtocol
import Databases
import Foundation
import Testing
@testable import ControlCommands
@testable import NotesCore

/// Строки и ячейки командами (T045): одна строка и пачка, значения по типам, вычисляемые, корзина, связи и сводки.
@MainActor @Suite struct RowCommandsTests {
    let fixture: DatabaseCommandFixture
    let tasks: UUID

    init() async throws {
        fixture = try DatabaseCommandFixture()
        tasks = try await fixture.createDatabase()
        for (name, type) in [("Часы", "number"), ("Тег", "select"), ("Метки", "multiSelect"), ("Срок", "date"), ("Готово", "checkbox"),
                             ("Заметка", "text"), ("Создано", "createdTime"), ("Статус", "status")] {
            try await fixture.ok("db.prop.add", ["database": "Задачи", "name": .string(name), "type": .string(type)])
        }
    }

    func row(_ title: String) throws -> Page {
        try #require(try fixture.rows(tasks).first { $0.title == title })
    }

    func cell(_ title: String, _ property: String) throws -> JSONValue? {
        try fixture.cell(try row(title).id, try fixture.property(property, in: tasks).id)
    }

    // MARK: Добавить

    @Test func addsOneRowWithValuesByType() async throws {
        let response = await fixture.run("db.row.add", ["database": "Задачи", "values": [
            "Название": "Отчёт", "Часы": 2.5, "Тег": "Срочно", "Метки": ["А", "Б"], "Срок": "2026-10-24", "Готово": true,
            "Заметка": "Купить **молоко**", "Статус": "В работе",
        ]])
        #expect(response.ok, "\(response.error?.message ?? "")")
        #expect(response.warnings.filter { $0.code == .optionCreated }.count == 3)
        let data = try #require(response.data)
        #expect(data["row"]?["title"] == "Отчёт")
        #expect(data["row"]?["values"]?["Тег"] == "Срочно")
        #expect(data["row"]?["values"]?["Метки"] == ["А", "Б"])
        #expect(data["row"]?["values"]?["Срок"] == "2026-10-24")
        #expect(data["row"]?["values"]?["Заметка"] == "Купить **молоко**")
        #expect(data["row"]?["values"]?["Статус"] == "В работе")
        #expect(try cell("Отчёт", "Часы") == .number(2.5))
        #expect(try cell("Отчёт", "Готово") == .bool(true))
        let tag = try fixture.property("Тег", in: tasks)
        #expect(try fixture.catalog(tasks).options[tag.id]?.map(\.name) == ["Срочно"])
    }

    @Test func addsBatchOfThousandRowsInOneStep() async throws {
        let rows: [ControlJSON] = (0..<1_000).map { ["Название": .string("Р\($0)"), "Часы": .number(Double($0)), "Тег": $0 % 2 == 0 ? "Чёт" : "Нечет"] }
        let data = try await fixture.ok("db.row.add", ["database": "Задачи", "rows": .array(rows)])
        #expect(data["count"] == 1_000)
        #expect(data["rows"]?.array?.count == 1_000)
        #expect(try fixture.rows(tasks).count == 1_000)
        #expect(try cell("Р999", "Часы") == .number(999))
        let tag = try fixture.property("Тег", in: tasks)
        #expect(try fixture.catalog(tasks).options[tag.id]?.count == 2)
    }

    @Test func batchWithOneBadRowWritesNothing() async throws {
        var rows: [ControlJSON] = (0..<10).map { ["Название": .string("Р\($0)"), "Тег": "Новый"] }
        rows[7] = ["Название": "Плохая", "Часы": "много"]
        let error = try await fixture.failure("db.row.add", ["database": "Задачи", "rows": .array(rows)])
        #expect(error.code == .invalidValue)
        #expect(error.details?["row"] == 7)
        #expect(error.details?["property"] == "Часы")
        #expect(try fixture.rows(tasks).isEmpty)
        let tag = try fixture.property("Тег", in: tasks)
        #expect(try fixture.catalog(tasks).options[tag.id]?.isEmpty ?? true)
    }

    @Test func rejectsWrongValueAndUnknownProperty() async throws {
        let wrong = try await fixture.failure("db.row.add", ["database": "Задачи", "values": ["Готово": "да"]])
        #expect(wrong.code == .invalidValue)
        #expect(wrong.details?["type"] == "checkbox")
        #expect(wrong.details?["example"] == true)
        let unknown = try await fixture.failure("db.row.add", ["database": "Задачи", "values": ["Нет такого": 1]])
        #expect(unknown.code == .propertyNotFound)
        let status = try await fixture.failure("db.row.add", ["database": "Задачи", "values": ["Статус": "Нет такого"]])
        #expect(status.code == .optionNotFound)
        #expect(try fixture.rows(tasks).isEmpty)
    }

    // MARK: Правка

    @Test func updatesRowAndSetsOrClearsCell() async throws {
        try await fixture.ok("db.row.add", ["database": "Задачи", "values": ["Название": "Отчёт", "Часы": 1]])
        try await fixture.ok("db.row.update", ["database": "Задачи", "row": "Отчёт", "values": ["Название": "Отчёт за месяц", "Часы": 3]])
        #expect(try cell("Отчёт за месяц", "Часы") == .number(3))
        let set = try await fixture.ok("db.cell.set", ["database": "Задачи", "row": "Отчёт за месяц", "property": "Срок",
                                                       "value": ["start": "2026-10-24T09:30", "end": "2026-10-25T10:00"]])
        #expect(set["row"]?["values"]?["Срок"]?["time"] == true)
        try await fixture.ok("db.cell.set", ["database": "Задачи", "row": "Отчёт за месяц", "property": "Часы", "value": .null])
        #expect(try cell("Отчёт за месяц", "Часы") == nil)
        let readOnly = try await fixture.failure("db.cell.set", ["database": "Задачи", "row": "Отчёт за месяц", "property": "Создано", "value": "2026-10-24"])
        #expect(readOnly.code == .readOnlyProperty)
        let missing = try await fixture.failure("db.row.update", ["database": "Задачи", "row": "Нет строки", "values": ["Часы": 1]])
        #expect(missing.code == .rowNotFound)
    }

    @Test func renamingRowRecordsAgentVersion() async throws {
        try await fixture.ok("db.row.add", ["database": "Задачи", "values": ["Название": "Отчёт", "Часы": 1]])
        let id = try row("Отчёт").id
        try await fixture.ok("db.cell.set", ["database": "Задачи", "row": "Отчёт", "property": "Часы", "value": 2])
        #expect(try fixture.host.versions.versions(ofPage: id).filter { $0.summary.agent != nil }.isEmpty, "Значение без названия — не правка страницы строки")
        try await fixture.ok("db.cell.set", ["database": "Задачи", "row": "Отчёт", "property": "Название", "value": "Итоги"])
        let versions = try fixture.host.versions.versions(ofPage: id).filter { $0.summary.agent != nil }
        #expect(versions.count == 1, "Название строки сменено без версии «до правки агента»")
        #expect(try versions.first.flatMap { try fixture.host.versions.snapshot($0.id) }?.title == "Отчёт")
    }

    @Test func trashesRestoresAndDuplicatesRows() async throws {
        try await fixture.ok("db.row.add", ["database": "Задачи", "rows": [["Название": "А", "Часы": 1], ["Название": "Б"]]])
        try await fixture.ok("db.row.trash", ["database": "Задачи", "rows": ["А", "Б"]])
        #expect(try fixture.rows(tasks).isEmpty)
        let id = try #require(try fixture.store.pageOutline().first { $0.title == "А" }?.id)
        try await fixture.ok("db.row.restore", ["database": "Задачи", "rows": [.string(id.controlText)]])
        #expect(try fixture.rows(tasks).map(\.title) == ["А"])
        let copies = try await fixture.ok("db.row.duplicate", ["database": "Задачи", "rows": ["А"]])
        #expect(copies["rows"]?[0]?["title"] == "А (1)")
        #expect(try cell("А (1)", "Часы") == .number(1))
    }

    // MARK: Связи

    @Test func linksAndUnlinksRowsWithPairedSideAndRollup() async throws {
        let clients = try await fixture.createDatabase("Клиенты")
        try await fixture.ok("db.prop.add", ["database": "Задачи", "name": "Клиент", "type": "relation",
                                             "config": ["target": "Клиенты", "related": "Задачи"]])
        try await fixture.ok("db.prop.add", ["database": "Клиенты", "name": "Число задач", "type": "rollup",
                                             "config": ["relation": "Задачи", "property": "Название", "calculation": "countAll"]])
        try await fixture.ok("db.row.add", ["database": "Клиенты", "rows": [["Название": "Альфа"], ["Название": "Бета"]]])
        try await fixture.ok("db.row.add", ["database": "Задачи", "rows": [["Название": "Т1", "Клиент": ["Альфа"]], ["Название": "Т2"]]])
        let linked = try await fixture.ok("db.relation.link", ["database": "Задачи", "row": "Т2", "property": "Клиент", "to": ["Альфа", "Бета"]])
        #expect(linked["row"]?["values"]?["Клиент"]?.array?.compactMap { $0["title"]?.string } == ["Альфа", "Бета"])

        let alpha = try #require(try fixture.rows(clients).first { $0.title == "Альфа" })
        let paired = try fixture.property("Задачи", in: clients)
        let rollup = try fixture.property("Число задач", in: clients)
        #expect(try RelationLinks.related(alpha.id, through: paired, in: fixture.store).map(\.title).sorted() == ["Т1", "Т2"])
        #expect(try fixture.computed(alpha.id, rollup.id) == .number(2))

        try await fixture.ok("db.relation.unlink", ["database": "Задачи", "row": "Т1", "property": "Клиент", "to": ["Альфа"]])
        #expect(try RelationLinks.related(alpha.id, through: paired, in: fixture.store).map(\.title) == ["Т2"])
        #expect(try fixture.computed(alpha.id, rollup.id) == .number(1))
        let notFound = try await fixture.failure("db.relation.link", ["database": "Задачи", "row": "Т1", "property": "Клиент", "to": ["Нет"]])
        #expect(notFound.code == .rowNotFound)
    }
}
