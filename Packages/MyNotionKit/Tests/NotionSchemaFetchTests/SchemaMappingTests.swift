import Foundation
import Testing
@testable import NotionSchemaFetch

/// Схема базы из сохранённых ответов Notion API (T106, research R19): без сети. Ответы — `Fixtures/*.json`;
/// «live-tasks» — настоящая схема «Задач» со страницы «MyNotion — базы 004», очищенная от людей и адресов.
enum Fixture {
    static func data(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"), "Нет фикстуры \(name)")
        return try Data(contentsOf: url)
    }

    static func schema(_ name: String) throws -> NotionDatabaseSchema {
        try NotionSchemaMapping.schema(fromDataSource: data(name))
    }
}

@Suite("Схема Notion: разбор ответов")
struct SchemaMappingTests {
    private func kinds(of schema: NotionDatabaseSchema) -> [String: NotionProperty.Kind] {
        Dictionary(uniqueKeysWithValues: schema.properties.map { ($0.name, $0.kind) })
    }

    @Test("Живая «Задачи»: каждый тип свойства Notion разобран, неподдержанные названы своим именем")
    func everyType() throws {
        let schema = try Fixture.schema("live-tasks-data-source")
        #expect(schema.title == "Задачи")
        #expect(schema.databaseId == "400714fdda698045a03ff04d83b47e70")
        #expect(schema.dataSourceId == "400714fdda69805f802d000b57b4f42a")
        let kinds = kinds(of: schema)
        #expect(kinds["Name"] == .title)
        #expect(kinds["URL"] == .url)
        #expect(kinds["Email"] == .email)
        #expect(kinds["Phone"] == .phone)
        #expect(kinds["Checkbox"] == .checkbox)
        #expect(kinds["Files & media"] == .files)
        #expect(kinds["Due Date"] == .date)
        #expect(kinds["Created time"] == .createdTime)
        #expect(kinds["Last edited time"] == .lastEditedTime)
        #expect(kinds["ID"] == .uniqueId(prefix: nil))
        #expect(kinds["Number"] == .number(format: nil))
        #expect(kinds["Multi-select"] == .multiSelect([]))
        for (name, notionType) in [("Person", "people"), ("Owner", "people"), ("Created by", "created_by"), ("Last edited by", "last_edited_by"),
                                   ("Button", "button"), ("Place", "place"), ("Verification", "verification")] {
            #expect(kinds[name] == .unsupported(notionType: notionType), "«\(name)»")
        }
        #expect(schema.properties.count == 26)
    }

    @Test("Выбор: варианты по порядку, цвета Notion как есть; незнакомый цвет — обычный")
    func optionsWithColors() throws {
        let schema = try Fixture.schema("live-tasks-data-source")
        guard case .select(let options)? = schema.property(named: "Select")?.kind else { Issue.record("Select не выбор"); return }
        #expect(options == [NotionOption(name: "Потом", color: "red"), NotionOption(name: "Обычно", color: "pink"),
                            NotionOption(name: "Срочно", color: "orange")])
        let json = """
        {"object":"data_source","id":"d1","title":[],"parent":{"type":"database_id","database_id":"b1"},
         "properties":{"X":{"id":"x","name":"X","type":"select","select":{"options":[
           {"id":"1","name":"Новый цвет","color":"lavender"},{"id":"2","name":"Без цвета"}]}}}}
        """
        let odd = try NotionSchemaMapping.schema(fromDataSource: Data(json.utf8))
        #expect(odd.property(named: "X")?.kind == .select([NotionOption(name: "Новый цвет", color: "default"),
                                                           NotionOption(name: "Без цвета", color: "default")]))
    }

    @Test("Статус: варианты с цветами и три группы по порядку Notion (To-do, In progress, Complete)")
    func statusGroups() throws {
        let schema = try Fixture.schema("import-tasks-data-source")
        guard case .status(let options, let groups)? = schema.property(named: "Статус")?.kind else { Issue.record("Статус не статус"); return }
        #expect(options.map(\.name) == ["Не начато", "В работе", "Готово", "Отложено"])
        #expect(options.map(\.color) == ["default", "blue", "green", "gray"])
        #expect(groups.map(\.group) == [.todo, .inProgress, .complete])
        #expect(groups.map(\.optionNames) == [["Не начато", "Отложено"], ["В работе"], ["Готово"]])
        // Живой пример: названия групп по-английски, у каждого варианта своя группа.
        guard case .status(_, let live)? = try Fixture.schema("live-tasks-data-source").property(named: "Status")?.kind else { return }
        #expect(live.map(\.group) == [.todo, .inProgress, .complete])
        #expect(live.map(\.optionNames) == [["Not started"], ["In progress"], ["Done"]])
    }

    @Test("Число: формат Notion → формат MyNotion; нет формата или незнакомый — простое число")
    func numberFormats() throws {
        let expected: [(String, String?)] = [
            ("number", nil), ("number_with_commas", "numberWithSeparators"), ("percent", "percent"), ("dollar", "dollar"),
            ("canadian_dollar", "canadianDollar"), ("hong_kong_dollar", "hongKongDollar"), ("argentine_peso", "argentinePeso"),
            ("ruble", "ruble"), ("euro", "euro"), ("peruvian_sol", "peruvianSol"), ("monopoly_money", nil),
        ]
        for (notion, mine) in expected {
            let json = """
            {"object":"data_source","id":"d1","title":[],"parent":{"type":"database_id","database_id":"b1"},
             "properties":{"N":{"id":"n","name":"N","type":"number","number":{"format":"\(notion)"}}}}
            """
            let schema = try NotionSchemaMapping.schema(fromDataSource: Data(json.utf8))
            #expect(schema.property(named: "N")?.kind == .number(format: mine), "\(notion)")
        }
    }

    @Test("Связь: цель и пара; односторонняя — без пары; id нормализованы (32 hex без дефисов)")
    func relations() throws {
        let tasks = try Fixture.schema("import-tasks-data-source")
        #expect(tasks.property(named: "Проект")?.kind == .relation(NotionRelation(
            targetDatabaseId: "a0000000000000000000000000000003", targetDataSourceId: "d0000000000000000000000000000003",
            pairedPropertyName: "Задачи")))
        // Живая: связь на саму базу, пара «Обратная».
        let live = try Fixture.schema("live-tasks-data-source")
        #expect(live.property(named: "Проект")?.kind == .relation(NotionRelation(
            targetDatabaseId: "400714fdda698045a03ff04d83b47e70", targetDataSourceId: "400714fdda69805f802d000b57b4f42a",
            pairedPropertyName: "Обратная")))
        #expect(live.property(named: "Обратная")?.kind == .relation(NotionRelation(
            targetDatabaseId: "400714fdda698045a03ff04d83b47e70", targetDataSourceId: "400714fdda69805f802d000b57b4f42a",
            pairedPropertyName: "Проект")))
        let single = """
        {"object":"data_source","id":"d1","title":[],"parent":{"type":"database_id","database_id":"b1"},
         "properties":{"R":{"id":"r","name":"R","type":"relation","relation":{"database_id":"A0000000-0000-0000-0000-00000000000B",
           "data_source_id":"c1","type":"single_property","single_property":{}}}}}
        """
        let schema = try NotionSchemaMapping.schema(fromDataSource: Data(single.utf8))
        #expect(schema.property(named: "R")?.kind == .relation(NotionRelation(
            targetDatabaseId: "a000000000000000000000000000000b", targetDataSourceId: "c1", pairedPropertyName: nil)))
    }

    @Test("Сводка: связь и свойство по названиям; функция Notion → вычисление MyNotion; групповые функции — без вычисления")
    func rollups() throws {
        let projects = try Fixture.schema("import-projects-data-source")
        #expect(projects.property(named: "Всего часов")?.kind == .rollup(NotionRollup(
            relationPropertyName: "Задачи", targetPropertyName: "Часы", function: "sum", calculation: "sum")))
        let live = try Fixture.schema("live-tasks-data-source")
        #expect(live.property(named: "Итог")?.kind == .rollup(NotionRollup(
            relationPropertyName: "Проект", targetPropertyName: "Number", function: "show_original", calculation: "showOriginal")))
        let table: [(String, String?)] = [
            ("count_all", "countAll"), ("count", "countAll"), ("count_values", "countValues"), ("count_unique_values", "countUnique"),
            ("count_empty", "countEmpty"), ("count_not_empty", "countNotEmpty"), ("unique", "showUnique"), ("show_unique", "showUnique"),
            ("percent_empty", "percentEmpty"), ("percent_not_empty", "percentNotEmpty"), ("sum", "sum"), ("average", "average"),
            ("median", "median"), ("min", "min"), ("max", "max"), ("range", "range"), ("earliest_date", "earliestDate"),
            ("latest_date", "latestDate"), ("date_range", "dateRange"), ("checked", "checked"), ("unchecked", "unchecked"),
            ("percent_checked", "percentChecked"), ("percent_unchecked", "percentUnchecked"), ("show_original", "showOriginal"),
            ("count_per_group", nil), ("percent_per_group", nil),
        ]
        for (function, calculation) in table {
            let json = """
            {"object":"data_source","id":"d1","title":[],"parent":{"type":"database_id","database_id":"b1"},
             "properties":{"S":{"id":"s","name":"S","type":"rollup","rollup":{"relation_property_name":"Связь",
               "rollup_property_name":"Число","function":"\(function)"}}}}
            """
            let schema = try NotionSchemaMapping.schema(fromDataSource: Data(json.utf8))
            #expect(schema.property(named: "S")?.kind == .rollup(NotionRollup(
                relationPropertyName: "Связь", targetPropertyName: "Число", function: function, calculation: calculation)), "\(function)")
        }
    }

    @Test("Формулы: текст выражения как отдал Notion, в том числе пустой")
    func formulas() throws {
        let live = try Fixture.schema("live-tasks-data-source")
        #expect(live.property(named: "Formula")?.kind == .formula(expression: "\"Привет, \" + prop(\"Name\")"))
        #expect(live.property(named: "Формула")?.kind == .formula(expression: ""))
    }

    @Test("Идентификатор свойства в ответе закодирован (%3C…) — разбирается; свойства отсортированы по названию")
    func propertyIds() throws {
        let live = try Fixture.schema("live-tasks-data-source")
        #expect(live.property(named: "URL")?.id == "<piY")
        #expect(live.property(named: "Проект")?.id == "MW:w")
        #expect(live.properties.map(\.name) == live.properties.map(\.name).sorted())
    }

    @Test("База: название, источники данных; ответ старой версии API (свойства прямо в базе) тоже читается")
    func databaseReference() throws {
        let reference = try NotionSchemaMapping.databaseReference(from: Fixture.data("import-tasks-database"))
        #expect(reference.id == "a0000000000000000000000000000002")
        #expect(reference.title == "Задачи")
        #expect(reference.dataSources == [NotionDataSourceReference(id: "d0000000000000000000000000000002", name: "Задачи")])
        #expect(reference.inlineSchema == nil)

        let old = """
        {"object":"database","id":"A0000000-0000-0000-0000-000000000009","title":[{"plain_text":"Старая"}],
         "properties":{"Name":{"id":"title","name":"Name","type":"title","title":{}}}}
        """
        let oldReference = try NotionSchemaMapping.databaseReference(from: Data(old.utf8))
        #expect(oldReference.dataSources.isEmpty)
        #expect(oldReference.inlineSchema?.databaseId == "a0000000000000000000000000000009")
        #expect(oldReference.inlineSchema?.property(named: "Name")?.kind == .title)
    }

    @Test("Не база Notion или не JSON — понятная ошибка, а не падение")
    func unreadable() {
        #expect(throws: NotionSchemaMappingError.self) { try NotionSchemaMapping.schema(fromDataSource: Data("не json".utf8)) }
        #expect(throws: NotionSchemaMappingError.self) { try NotionSchemaMapping.schema(fromDataSource: Data("{\"object\":\"page\"}".utf8)) }
        #expect(throws: NotionSchemaMappingError.self) { try NotionSchemaMapping.databaseReference(from: Data("[]".utf8)) }
    }
}
