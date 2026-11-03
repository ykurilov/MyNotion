import ControlProtocol
import Databases
import Foundation
import Testing
@testable import ControlCommands
@testable import NotesCore

/// Шаблоны строк командами `db template …` и `db row add --template` (004, US6): список, новый, по умолчанию, копия,
/// удаление, шаблон на пустую строку.
@MainActor @Suite struct TemplateCommandsTests {
    let fixture: DatabaseCommandFixture
    let tasks: UUID

    init() async throws {
        fixture = try DatabaseCommandFixture()
        tasks = try await fixture.createDatabase()
        try await fixture.ok("db.prop.add", ["database": "Задачи", "name": "Часы", "type": "number"])
    }

    func templates() async throws -> [ControlJSON] {
        try await fixture.ok("db.template.list", ["database": "Задачи"])["templates"]?.array ?? []
    }

    func titles() async throws -> [String] {
        try await templates().compactMap { $0["title"]?.string }
    }

    @discardableResult
    func addTemplate(_ title: String, hours: Double? = nil) async throws -> String {
        let data = try await fixture.ok("db.template.add", ["database": "Задачи", "title": .string(title)])
        let id = try #require(data["template"]?["id"]?.string)
        if let hours {
            try await fixture.ok("db.cell.set", ["database": "Задачи", "row": .string(id), "property": "Часы", "value": .number(hours)])
        }
        return id
    }

    @Test func emptyDatabaseHasNoTemplates() async throws {
        let data = try await fixture.ok("db.template.list", ["database": "Задачи"])
        #expect(data["templates"]?.array?.isEmpty == true)
        #expect(data["defaultTemplate"] == .null)
    }

    @Test func addedTemplateIsListedAndIsNotARow() async throws {
        let id = try await addTemplate("Еженедельная")
        let listed = try await templates()
        #expect(listed.count == 1)
        #expect(listed.first?["id"]?.string == id)
        #expect(listed.first?["title"] == "Еженедельная")
        #expect(listed.first?["isDefault"] == false)
        let rows = try await fixture.ok("db.rows", ["database": "Задачи"])
        #expect(DatabaseCommandFixture.rowTitles(rows).isEmpty)
    }

    @Test func defaultByTitleThenNoneAndNewRowFollowsIt() async throws {
        try await addTemplate("Еженедельная", hours: 3)
        let chosen = try await fixture.ok("db.template.default", ["database": "Задачи", "template": "еженедельная"])
        #expect(chosen["defaultTemplate"]?["title"] == "Еженедельная")
        #expect(try await templates().first?["isDefault"] == true)

        let added = try await fixture.ok("db.row.add", ["database": "Задачи", "values": [:]])
        #expect(added["row"]?["title"] == "Еженедельная")
        #expect(added["row"]?["values"]?["Часы"] == 3)

        let cleared = try await fixture.ok("db.template.default", ["database": "Задачи", "none": true])
        #expect(cleared["defaultTemplate"] == .null)
        #expect(try await templates().first?["isDefault"] == false)
    }

    @Test func defaultNeedsTemplateOrNone() async throws {
        let error = try await fixture.failure("db.template.default", ["database": "Задачи"])
        #expect(error.code == .missingArgument || error.code == .invalidValue)
    }

    @Test func rowAddWithTemplateKeepsGivenValuesOnTop() async throws {
        try await addTemplate("Еженедельная", hours: 3)
        let data = try await fixture.ok("db.row.add", ["database": "Задачи", "template": "Еженедельная",
                                                        "values": ["Название": "Отчёт"]])
        #expect(data["row"]?["title"] == "Отчёт")
        #expect(data["row"]?["values"]?["Часы"] == 3)
        let override = try await fixture.ok("db.row.add", ["database": "Задачи", "template": "Еженедельная", "values": ["Часы": 8]])
        #expect(override["row"]?["title"] == "Еженедельная")
        #expect(override["row"]?["values"]?["Часы"] == 8)
    }

    @Test func rowAddWithTemplateWorksForBatch() async throws {
        try await addTemplate("Еженедельная", hours: 3)
        let data = try await fixture.ok("db.row.add", ["database": "Задачи", "template": "Еженедельная",
                                                       "rows": [["Название": "А"], ["Название": "Б"]]])
        #expect(data["count"] == 2)
        #expect(data["rows"]?.array?.compactMap { $0["values"]?["Часы"] } == [3, 3])
    }

    @Test func duplicateMakesCopyRightAfterOriginal() async throws {
        try await addTemplate("Еженедельная", hours: 3)
        try await addTemplate("Разовая")
        let data = try await fixture.ok("db.template.duplicate", ["database": "Задачи", "template": "Еженедельная"])
        #expect(data["template"]?["title"] == "Еженедельная (1)")
        #expect(try await titles() == ["Еженедельная", "Еженедельная (1)", "Разовая"])
    }

    @Test func deleteRemovesTemplateAndResetsDefault() async throws {
        try await addTemplate("Еженедельная")
        try await fixture.ok("db.template.default", ["database": "Задачи", "template": "Еженедельная"])
        try await fixture.ok("db.template.delete", ["database": "Задачи", "template": "Еженедельная"])
        let data = try await fixture.ok("db.template.list", ["database": "Задачи"])
        #expect(data["templates"]?.array?.isEmpty == true)
        #expect(data["defaultTemplate"] == .null)
    }

    @Test func applyFillsEmptyRowAndRefusesFilledOne() async throws {
        try await addTemplate("Еженедельная", hours: 3)
        let empty = try await fixture.ok("db.row.add", ["database": "Задачи", "values": ["Название": "Пятница"]])
        let rowId = try #require(empty["row"]?["id"]?.string)
        let applied = try await fixture.ok("db.template.apply", ["database": "Задачи", "row": .string(rowId), "template": "Еженедельная"])
        #expect(applied["row"]?["title"] == "Пятница")
        #expect(applied["row"]?["values"]?["Часы"] == 3)

        try await fixture.ok("page.append", ["page": .string(rowId), "markdown": "Текст"])
        let error = try await fixture.failure("db.template.apply", ["database": "Задачи", "row": .string(rowId), "template": "Еженедельная"])
        #expect(error.code == .invalidValue)
    }

    @Test func unknownTemplateIsTemplateNotFound() async throws {
        try await addTemplate("Еженедельная")
        for (command, extra) in [("db.template.default", [:]), ("db.template.delete", [:]), ("db.template.duplicate", [:]),
                                 ("db.row.add", ["values": [:]])] as [(String, [String: ControlJSON])] {
            var args: [String: ControlJSON] = ["database": "Задачи", "template": "Нет такого"]
            args.merge(extra) { first, _ in first }
            let error = try await fixture.failure(command, args)
            #expect(error.code == .templateNotFound, "\(command)")
        }
    }

}
