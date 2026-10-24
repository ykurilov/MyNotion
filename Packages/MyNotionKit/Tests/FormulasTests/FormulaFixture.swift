import Foundation
@testable import Formulas

/// Строка-пример для формул: значения свойств по названию (оно же id в тестах), связанные страницы, часы и календарь
/// с поясом Москвы и русским языком.
struct FormulaFixture: FormulaContext {
    static let row = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let projectA = UUID(uuidString: "00000000-0000-0000-0000-00000000000a")!
    static let projectB = UUID(uuidString: "00000000-0000-0000-0000-00000000000b")!

    var values: [UUID: [String: FormulaValue]]
    var now: Date
    var calendar: Calendar

    init(values: [String: FormulaValue] = [:]) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
        calendar.locale = Locale(identifier: "ru_RU")
        self.calendar = calendar
        now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 17, minute: 56))!
        self.values = [Self.row: values,
                       Self.projectA: ["Название": .text("Альфа"), "Бюджет": .number(100)],
                       Self.projectB: ["Название": .text("Бета"), "Бюджет": .number(250)]]
    }

    func value(ofProperty propertyId: String, row rowId: UUID) -> FormulaValue { values[rowId]?[propertyId] ?? .empty }
    func title(ofPage pageId: UUID) -> String? { values[pageId]?["Название"]?.text }

    func day(_ year: Int, _ month: Int, _ day: Int, _ hour: Int? = nil, _ minute: Int = 0) -> FormulaValue {
        let date = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour ?? 0, minute: minute))!
        return .date(FormulaDate(start: date, hasTime: hour != nil))
    }

    /// Итог формулы; ошибка разбора или вычисления — бросается.
    func evaluate(_ source: String) throws -> FormulaValue {
        try FormulaEvaluator(context: self, rowId: Self.row).value(of: try FormulaParser.parse(source))
    }

    /// Итог текстом, как в примерах редактора.
    func text(_ source: String) throws -> String { FormulaText.format(try evaluate(source), context: self) }

    /// Итог в ячейке: ошибка вычисления — пусто.
    func cell(_ source: String) throws -> FormulaValue { FormulaEvaluator.evaluate(try FormulaParser.parse(source), row: Self.row, context: self) }
}

/// Схема «Задач» со связью на «Проекты».
struct FormulaSchemaFixture: FormulaSchema {
    var tasks: [FormulaProperty] = [
        FormulaProperty(id: "id-name", name: "Название", type: .text),
        FormulaProperty(id: "id-due", name: "Срок", type: .date),
        FormulaProperty(id: "id-done", name: "Готово", type: .bool),
        FormulaProperty(id: "id-price", name: "Цена", type: .number),
        FormulaProperty(id: "id-tags", name: "Теги", type: .list(.text)),
        FormulaProperty(id: "id-project", name: "Проект", type: .list(.page(database: "projects"))),
        FormulaProperty(id: "id-author", name: "Автор", type: .text, isSupported: false),
        FormulaProperty(id: "id-total", name: "Итог", type: .any, formula: #"prop("id-sum") + 1"#),
        FormulaProperty(id: "id-sum", name: "Сумма", type: .any, formula: #"prop("id-total") * 2"#),
        FormulaProperty(id: "id-label", name: "Метка", type: .any, formula: #"if(prop("id-done"), "✅", "⏳")"#),
    ]
    var projects: [FormulaProperty] = [
        FormulaProperty(id: "pid-name", name: "Название", type: .text),
        FormulaProperty(id: "pid-budget", name: "Бюджет", type: .number),
    ]

    func property(_ nameOrId: String, inDatabase database: String?) -> FormulaProperty? {
        let list = database == "projects" ? projects : (database == nil ? tasks : [])
        return list.first { $0.id == nameOrId } ?? list.first { $0.name == nameOrId }
    }

    func owner(_ name: String) -> FormulaProperty { tasks.first { $0.name == name }! }
}
