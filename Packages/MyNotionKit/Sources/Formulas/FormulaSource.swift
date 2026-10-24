/// Текст формулы для Юрия и для хранения. Юрий пишет `prop("Срок")`, в свойстве хранится `prop("<id>")`: переименование
/// свойства не ломает формулы, а редактор показывает новое название (contracts/formulas.md, «переименование…»).
public enum FormulaSource {
    /// Текст редактора → текст хранения: названия свойств заменяются на id. Ошибка — как у проверки.
    public static func stored(_ display: String, schema: any FormulaSchema, owner: FormulaProperty? = nil) throws(FormulaError) -> String {
        let check = try FormulaTypeChecker.check(display, schema: schema, owner: owner)
        return replacing(display, check.references) { $0.id }
    }

    /// Текст хранения → текст редактора: id заменяются на названия. Удалённое свойство остаётся как есть
    /// (редактор покажет «Нет свойства …»).
    public static func display(_ stored: String, schema: any FormulaSchema) -> String {
        if let check = try? FormulaTypeChecker.check(stored, schema: schema) {
            return replacing(stored, check.references) { $0.name }
        }
        // С ошибкой — только свойства своей базы, по словам текста.
        guard let tokens = try? FormulaLexer.tokens(stored) else { return stored }
        var references: [FormulaPropertyReference] = []
        for index in tokens.indices.dropLast(2) {
            guard case .identifier("prop") = tokens[index].kind, case .symbol("(") = tokens[index + 1].kind,
                  case .text(let key) = tokens[index + 2].kind, index == 0 || tokens[index - 1].kind != .symbol("."),
                  let property = schema.property(key, inDatabase: nil) else { continue }
            references.append(FormulaPropertyReference(range: tokens[index + 2].range, property: property))
        }
        return replacing(stored, references) { $0.name }
    }

    /// Текст в кавычках для `prop("…")`.
    public static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func replacing(_ source: String, _ references: [FormulaPropertyReference], with key: (FormulaProperty) -> String) -> String {
        var characters = Array(source)
        for reference in references.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            characters.replaceSubrange(reference.range, with: Array(quoted(key(reference.property))))
        }
        return String(characters)
    }
}
