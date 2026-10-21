import Foundation
import Formulas
import NotesCore

extension DatabaseOperations {
    /// «Готово» в редакторе формулы (US5): текст Юрия (с названиями свойств) проверяется — ошибка разбора, типов или круг
    /// не сохраняются; в свойство пишется текст с id и тип итога. Полный пересчёт строк идёт в фоне (подписчик записи).
    /// ⌘Z возвращает прежнюю формулу.
    @discardableResult
    public func setFormula(_ propertyId: UUID, display: String) throws -> FormulaType {
        guard let property = try store.write({ tx in try tx.property(propertyId) }), property.kind == .formula else {
            throw NotesStoreError.invalidRecord("свойство — не формула")
        }
        let schema = try DatabaseFormulaSchema.read(property.databaseId, in: store)
        let owner = DatabaseFormulaSchema.formulaProperty(property)
        let trimmed = display.trimmingCharacters(in: .whitespacesAndNewlines)
        var stored = "", type = FormulaType.any
        if !trimmed.isEmpty {
            stored = try FormulaSource.stored(display, schema: schema, owner: owner)
            type = try FormulaTypeChecker.check(stored, schema: schema, owner: owner).type
        }
        try replaceFormulaConfig(propertyId, expression: stored, resultType: type.configValue)
        return type
    }

    private func replaceFormulaConfig(_ propertyId: UUID, expression: String, resultType: String) throws {
        try perform("Правка формулы") { transaction in
            guard var property = try transaction.property(propertyId) else { throw NotesStoreError.invalidRecord("свойства нет") }
            let previous = (property.config["expression"]?.string ?? "", property.config["resultType"]?.string ?? "unknown")
            property.config["expression"] = .string(expression)
            property.config["resultType"] = .string(resultType)
            try transaction.saveProperty(property)
            return ((), { try $0.replaceFormulaConfig(propertyId, expression: previous.0, resultType: previous.1) })
        }
    }
}
