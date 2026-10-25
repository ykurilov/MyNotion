import ControlProtocol
import Databases
import Foundation
import Testing
@testable import ControlCommands
@testable import NotesCore

/// Схема базы командами (T044): база, свойства всех типов 004 и их настройки, смена типа, варианты и группы статуса.
@MainActor @Suite struct SchemaCommandsTests {
    let fixture: DatabaseCommandFixture

    init() throws {
        fixture = try DatabaseCommandFixture()
    }

    // MARK: База

    @Test func createsFullPageAndInlineDatabase() async throws {
        let full = try await fixture.ok("db.create", ["parent": "Проекты", "title": "Задачи"])
        #expect(full["database"]?["kind"] == "database")
        #expect(full["database"]?["title"] == "Задачи")
        let fullId = try #require(full["database"]?["id"]?.string.flatMap(UUID.init(uuidString:)))
        let anchor = try #require(try fixture.store.pageContent(fixture.root.id)?.blocks.first)
        let inline = try await fixture.ok("db.create", ["parent": "Проекты", "title": "Встречи", "inline": true,
                                                        "after": .string(anchor.id.controlText)])
        let inlineId = try #require(inline["database"]?["id"]?.string.flatMap(UUID.init(uuidString:)))
        let blocks = try #require(try fixture.store.pageContent(fixture.root.id)?.blocks)
        #expect(blocks.map(\.kind) == [.paragraph, .database, .pageLink])
        #expect(blocks[1].linkedPageId == inlineId)
        #expect(blocks[2].linkedPageId == fullId)
        #expect(inline["viewId"]?.string != nil)
    }

    @Test func schemaListsPropertiesOptionsAndViews() async throws {
        let id = try await fixture.createDatabase()
        try await fixture.ok("db.prop.add", ["database": "Задачи", "name": "Статус", "type": "status"])
        let schema = try await fixture.ok("db.schema", ["database": .string(id.controlText)])
        let properties = try #require(schema["properties"]?.array)
        #expect(properties.map { $0["name"]?.string } == ["Название", "Статус"])
        #expect(properties[1]["type"] == "status")
        let options = try #require(properties[1]["options"]?.array)
        #expect(options.compactMap { $0["group"]?.string } == ["todo", "inProgress", "complete"])
        #expect(schema["views"]?[0]?["name"] == "Таблица")
        #expect(schema["database"]?["id"] == .string(id.controlText))
    }

    // MARK: Свойства

    @Test func addsPropertyOfEveryKindWithConfig() async throws {
        let tasks = try await fixture.createDatabase()
        _ = try await fixture.createDatabase("Клиенты")
        let simple = ["text", "number", "select", "multiSelect", "status", "date", "checkbox", "url", "email", "phone", "files",
                      "createdTime", "lastEditedTime", "uniqueId"]
        for kind in simple {
            let config: ControlJSON = switch kind {
            case "number": ["format": "percent", "decimals": 1]
            case "uniqueId": ["prefix": "TASK"]
            case "date": ["dateFormat": "iso"]
            default: [:]
            }
            let data = try await fixture.ok("db.prop.add", ["database": "Задачи", "name": .string("П-\(kind)"), "type": .string(kind),
                                                            "config": config])
            #expect(data["property"]?["type"] == .string(kind))
        }
        #expect(try fixture.property("П-number", in: tasks).config["format"] == "percent")
        #expect(try fixture.property("П-uniqueId", in: tasks).config["prefix"] == "TASK")

        let relation = try await fixture.ok("db.prop.add", ["database": "Задачи", "name": "Клиент", "type": "relation",
                                                            "config": ["target": "Проекты/Клиенты", "limit": "one", "related": "Задачи"]])
        #expect(relation["property"]?["config"]?["limit"] == "one")
        let clientsId = try #require(try fixture.store.pageOutline().first { $0.title == "Клиенты" }?.id)
        #expect(try fixture.catalog(clientsId).properties.contains { $0.name == "Задачи" && $0.kind == .relation })

        try await fixture.ok("db.prop.add", ["database": "Задачи", "name": "Часы", "type": "number"])
        let rollup = try await fixture.ok("db.prop.add", ["database": "Задачи", "name": "Сводка", "type": "rollup",
                                                          "config": ["relation": "Клиент", "property": "Название", "calculation": "countAll"]])
        let relationId = try fixture.property("Клиент", in: tasks).id
        #expect(rollup["property"]?["config"]?["relationPropertyId"] == .string(relationId.controlText))
        #expect(rollup["property"]?["config"]?["calculation"] == "countAll")

        let formula = try await fixture.ok("db.prop.add", ["database": "Задачи", "name": "Двойные", "type": "formula",
                                                           "config": ["formula": #"prop("Часы") * 2"#]])
        #expect(formula["property"]?["formula"] == #"prop("Часы") * 2"#)
        #expect(try fixture.property("Двойные", in: tasks).config["resultType"] == "number")
    }

    @Test func updatesNameNumberFormatRelationRollupAndFormula() async throws {
        let tasks = try await fixture.createDatabase()
        _ = try await fixture.createDatabase("Клиенты")
        try await fixture.ok("db.prop.add", ["database": "Задачи", "name": "Цена", "type": "number"])
        try await fixture.ok("db.prop.update", ["database": "Задачи", "property": "Цена", "name": "Сумма",
                                                "config": ["format": "ruble", "decimals": 2]])
        let price = try fixture.property("Сумма", in: tasks)
        #expect(price.config["format"] == "ruble")
        #expect(price.config["decimals"] == 2)

        try await fixture.ok("db.prop.add", ["database": "Задачи", "name": "Клиент", "type": "relation", "config": ["target": "Клиенты"]])
        try await fixture.ok("db.prop.update", ["database": "Задачи", "property": "Клиент", "config": ["limit": "one", "related": "Заказы"]])
        let relation = try fixture.property("Клиент", in: tasks)
        #expect(relation.relationLimit == .one)
        let clientsId = try #require(try fixture.store.pageOutline().first { $0.title == "Клиенты" }?.id)
        #expect(try fixture.catalog(clientsId).properties.contains { $0.name == "Заказы" })
        try await fixture.ok("db.prop.update", ["database": "Задачи", "property": "Клиент", "config": ["related": false]])
        #expect(!(try fixture.catalog(clientsId).properties.contains { $0.name == "Заказы" }))

        try await fixture.ok("db.prop.add", ["database": "Задачи", "name": "Сводка", "type": "rollup"])
        try await fixture.ok("db.prop.update", ["database": "Задачи", "property": "Сводка",
                                                "config": ["relation": "Клиент", "property": "Название", "calculation": "countValues"]])
        #expect(try fixture.property("Сводка", in: tasks).config["calculation"] == "countValues")

        try await fixture.ok("db.prop.add", ["database": "Задачи", "name": "Итого", "type": "formula"])
        let updated = try await fixture.ok("db.prop.update", ["database": "Задачи", "property": "Итого", "formula": #"prop("Сумма") + 1"#])
        #expect(updated["property"]?["formula"] == #"prop("Сумма") + 1"#)
        let error = try await fixture.failure("db.prop.update", ["database": "Задачи", "property": "Итого", "formula": #"prop("Нет такого") + 1"#])
        #expect(error.code == .invalidFormula)
        #expect(error.details?["from"]?.int != nil)
        #expect(error.details?["to"]?.int != nil)
        #expect(try fixture.property("Итого", in: tasks).config["expression"]?.string?.contains(price.id.uuidString.lowercased()) == true)
    }

    @Test func changesTypeConvertingValues() async throws {
        let tasks = try await fixture.createDatabase()
        try await fixture.ok("db.prop.add", ["database": "Задачи", "name": "Метка", "type": "select"])
        try await fixture.ok("db.row.add", ["database": "Задачи", "values": ["Название": "Отчёт", "Метка": "Срочно"]])
        let data = try await fixture.ok("db.prop.type", ["database": "Задачи", "property": "Метка", "type": "text"])
        #expect(data["property"]?["type"] == "text")
        let row = try #require(try fixture.rows(tasks).first)
        let value = try fixture.cell(row.id, try fixture.property("Метка", in: tasks).id)
        #expect(value.flatMap { try? $0.decoded(as: InlineText.self) }?.string == "Срочно")
    }

    @Test func changesTypeOnLargeDatabaseBeforeAnswering() async throws {
        let tasks = try await fixture.createDatabase()
        try await fixture.ok("db.prop.add", ["database": "Задачи", "name": "Часы", "type": "text"])
        let rows: [ControlJSON] = (0..<DatabaseOperations.backgroundRewriteThreshold).map { ["Название": .string("Р\($0)"), "Часы": .string("\($0)")] }
        try await fixture.ok("db.row.add", ["database": "Задачи", "rows": .array(rows)])
        try await fixture.ok("db.prop.type", ["database": "Задачи", "property": "Часы", "type": "number"])
        let hours = try fixture.property("Часы", in: tasks)
        #expect(hours.kind == .number)
        let last = try #require(try fixture.rows(tasks).first { $0.title == "Р999" })
        #expect(try fixture.cell(last.id, hours.id) == .number(999))
    }

    @Test func batchRollsBackLargeTypeChangeBeforeAnswering() async throws {
        let tasks = try await fixture.createDatabase()
        try await fixture.ok("db.prop.add", ["database": "Задачи", "name": "Часы", "type": "text"])
        let rows: [ControlJSON] = (0..<DatabaseOperations.backgroundRewriteThreshold).map { ["Название": .string("Р\($0)"), "Часы": .string("\($0)")] }
        try await fixture.ok("db.row.add", ["database": "Задачи", "rows": .array(rows)])
        let response = await fixture.run("batch", ["steps": [
            ["command": "db.prop.type", "args": ["database": "Задачи", "property": "Часы", "type": "number"]],
            ["command": "page.rename", "args": ["page": "Нет такой страницы", "title": "Б"]],
        ]])
        #expect(response.error?.code == .batchFailed)
        let hours = try fixture.property("Часы", in: tasks)
        #expect(hours.kind == .text, "«Пакет откачен» пришёл раньше, чем вернулся тип свойства")
        let last = try #require(try fixture.rows(tasks).first { $0.title == "Р999" })
        #expect(try fixture.cell(last.id, hours.id).flatMap { try? $0.decoded(as: InlineText.self) }?.string == "999")
    }

    @Test func movesDuplicatesDeletesAndRestoresProperty() async throws {
        let tasks = try await fixture.createDatabase()
        for name in ["А", "Б", "В"] { try await fixture.ok("db.prop.add", ["database": "Задачи", "name": .string(name), "type": "text"]) }
        try await fixture.ok("db.prop.move", ["database": "Задачи", "property": "В", "after": "Название"])
        #expect(try fixture.catalog(tasks).properties.map(\.name) == ["Название", "В", "А", "Б"])
        try await fixture.ok("db.prop.move", ["database": "Задачи", "property": "Б", "first": true])
        #expect(try fixture.catalog(tasks).properties.map(\.name).first == "Б")
        let copy = try await fixture.ok("db.prop.duplicate", ["database": "Задачи", "property": "А"])
        #expect(copy["property"]?["name"] == "А (1)")
        try await fixture.ok("db.prop.delete", ["database": "Задачи", "property": "А"])
        #expect(!(try fixture.catalog(tasks).properties.contains { $0.name == "А" }))
        try await fixture.ok("db.prop.restore", ["database": "Задачи", "property": "А"])
        #expect(try fixture.catalog(tasks).properties.contains { $0.name == "А" })
        let error = try await fixture.failure("db.prop.delete", ["database": "Задачи", "property": "Нет такого"])
        #expect(error.code == .propertyNotFound)
    }

    // MARK: Варианты

    @Test func editsOptionsAndStatusGroups() async throws {
        let tasks = try await fixture.createDatabase()
        try await fixture.ok("db.prop.add", ["database": "Задачи", "name": "Тег", "type": "select"])
        let added = try await fixture.ok("db.option.add", ["database": "Задачи", "property": "Тег", "option": "Срочно", "color": "red"])
        #expect(added["option"]?["color"] == "red")
        try await fixture.ok("db.option.add", ["database": "Задачи", "property": "Тег", "option": "Потом"])
        try await fixture.ok("db.option.rename", ["database": "Задачи", "property": "Тег", "option": "Потом", "name": "Позже"])
        try await fixture.ok("db.option.color", ["database": "Задачи", "property": "Тег", "option": "Позже", "color": "blue"])
        try await fixture.ok("db.option.move", ["database": "Задачи", "property": "Тег", "option": "Позже", "first": true])
        let tag = try fixture.property("Тег", in: tasks)
        #expect(try fixture.catalog(tasks).options[tag.id]?.map(\.name) == ["Позже", "Срочно"])
        #expect(try fixture.catalog(tasks).options[tag.id]?.first?.color == "blue")
        try await fixture.ok("db.option.delete", ["database": "Задачи", "property": "Тег", "option": "Срочно"])
        #expect(try fixture.catalog(tasks).options[tag.id]?.map(\.name) == ["Позже"])

        try await fixture.ok("db.prop.add", ["database": "Задачи", "name": "Статус", "type": "status"])
        try await fixture.ok("db.option.add", ["database": "Задачи", "property": "Статус", "option": "Ревью", "group": "inProgress"])
        let status = try fixture.property("Статус", in: tasks)
        #expect(try fixture.catalog(tasks).options[status.id]?.first { $0.name == "Ревью" }?.statusGroup == .inProgress)
        try await fixture.ok("db.option.move", ["database": "Задачи", "property": "Статус", "option": "Ревью", "group": "complete"])
        #expect(try fixture.catalog(tasks).options[status.id]?.first { $0.name == "Ревью" }?.statusGroup == .complete)
        let error = try await fixture.failure("db.option.rename", ["database": "Задачи", "property": "Статус", "option": "Нет", "name": "X"])
        #expect(error.code == .optionNotFound)
    }
}
