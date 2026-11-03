import Formulas
import Foundation
import Testing
@testable import NotionSchemaFetch

/// Перевод формул Notion в язык MyNotion (T106): язык один — формулы Notion 2.0; свойства по названиям заменяются
/// на id, чужое — строка отчёта с причиной.
@Suite("Схема Notion: перевод формул")
struct FormulaTranslationTests {
    private struct Schema: FormulaSchema {
        let properties: [FormulaProperty]
        func property(_ nameOrId: String, inDatabase database: String?) -> FormulaProperty? {
            guard database == nil else { return nil }
            return properties.first { $0.id == nameOrId } ?? properties.first { $0.name == nameOrId }
        }
    }

    private let schema = Schema(properties: [
        FormulaProperty(id: "11111111-1111-1111-1111-111111111111", name: "Name", type: .text),
        FormulaProperty(id: "22222222-2222-2222-2222-222222222222", name: "Часы", type: .number),
        FormulaProperty(id: "33333333-3333-3333-3333-333333333333", name: "Готово", type: .bool),
        FormulaProperty(id: "44444444-4444-4444-4444-444444444444", name: "Срок", type: .date),
    ])

    private func stored(_ expression: String, names: [String: String] = [:]) -> String? {
        if case .translated(let stored, _) = NotionFormula.translate(expression, propertyNamesById: names, schema: schema) { return stored }
        return nil
    }

    private func failure(_ expression: String, names: [String: String] = [:]) -> String? {
        if case .notTranslated(let reason) = NotionFormula.translate(expression, propertyNamesById: names, schema: schema) { return reason }
        return nil
    }

    @Test("Формула Notion с prop(\"Название\") хранится с id свойств")
    func namesBecomeIds() {
        #expect(stored("prop(\"Часы\") * 2") == "prop(\"22222222-2222-2222-2222-222222222222\") * 2")
        #expect(stored("\"Привет, \" + prop(\"Name\")") == "\"Привет, \" + prop(\"11111111-1111-1111-1111-111111111111\")")
        #expect(stored("if(prop(\"Готово\"), \"Да\", \"Нет\")") == "if(prop(\"33333333-3333-3333-3333-333333333333\"), \"Да\", \"Нет\")")
    }

    @Test("Показ для Юрия остаётся с названиями")
    func displayKeepsNames() {
        guard case .translated(_, let display) = NotionFormula.translate("dateBetween(prop(\"Срок\"), now(), \"days\")",
                                                                         propertyNamesById: [:], schema: schema) else {
            Issue.record("не переведена"); return
        }
        #expect(display == "dateBetween(prop(\"Срок\"), now(), \"days\")")
    }

    @Test("Ссылка Notion {{notion:block_property:…}} заменяется названием по id свойства")
    func blockPropertyTokens() {
        let expression = "{{notion:block_property:ch:00000000-0000-0000-0000-000000000000:abc}} * 3"
        #expect(stored(expression, names: ["ch": "Часы"]) == "prop(\"22222222-2222-2222-2222-222222222222\") * 3")
        // Идентификатор в токене закодирован, а в словаре — нет.
        let encoded = "{{notion:block_property:%3Cp:00000000-0000-0000-0000-000000000000:abc}}.length()"
        #expect(stored(encoded, names: ["<p": "Name"]) == "prop(\"11111111-1111-1111-1111-111111111111\").length()")
        #expect(failure("{{notion:block_property:zz:00000000-0000-0000-0000-000000000000:abc}} + 1", names: [:])?.contains("свойств") == true)
    }

    @Test("Название с кавычкой и обратной чертой в prop(…) не ломает перевод")
    func quotedNames() {
        let tricky = Schema(properties: [FormulaProperty(id: "55555555-5555-5555-5555-555555555555", name: "Цена \"в\" долларах", type: .number)])
        let outcome = NotionFormula.translate("prop(\"Цена \\\"в\\\" долларах\") + 1", propertyNamesById: [:], schema: tricky)
        #expect(outcome == .translated(stored: "prop(\"55555555-5555-5555-5555-555555555555\") + 1",
                                       display: "prop(\"Цена \\\"в\\\" долларах\") + 1"))
    }

    @Test("Функция, которой нет в MyNotion, — строка отчёта с названием функции")
    func unsupportedFunction() {
        let reason = failure("style(prop(\"Name\"), \"b\")")
        #expect(reason?.contains("style") == true)
        #expect(reason?.contains("не поддерживается") == true)
        #expect(failure("name(prop(\"Name\"))")?.contains("name") == true)
    }

    @Test("Нет свойства, пустая формула, ошибка разбора — причина по-русски, перевода нет")
    func failures() {
        #expect(failure("prop(\"Нет такого\") + 1")?.contains("Нет такого") == true)
        #expect(failure("   ") == "формула пустая")
        #expect(failure("prop(\"Часы\") +") != nil)
        #expect(stored("prop(\"Часы\") +") == nil)
    }
}
