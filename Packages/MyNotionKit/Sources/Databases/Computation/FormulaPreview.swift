import Foundation
import Formulas
import NotesCore

/// Итог формулы для строки-примера в редакторе («Предпросмотр с <строка ▾>»): значение и текст или текст ошибки
/// вычисления (в ячейке такая ошибка — пусто, в редакторе — её текст, contracts/formulas.md, «Итог»).
public enum FormulaPreview {
    public struct Output: Sendable, Hashable {
        public var value: FormulaValue
        /// Итог текстом, как в примерах редактора; пусто — «Нет итога».
        public var text: String
    }

    /// `stored` — текст хранения (с id свойств).
    public static func evaluate(_ stored: String, row: UUID, databaseId: UUID, store: NotesStore, now: Date = Date(),
                                calendar: Calendar = .current) -> Result<Output, FormulaError> {
        do {
            let expression = try FormulaParser.parse(stored)
            return try store.database.dbWriter.read { db in
                let catalog = try DatabaseCatalog.read(databaseId, in: db)
                let inputs = try FormulaInputs(rows: [row], needed: expression.referencedProperties, catalog: catalog, now: now, calendar: calendar, in: db)
                do {
                    let value = try FormulaEvaluator(context: inputs, rowId: row).value(of: expression)
                    return .success(Output(value: value, text: FormulaText.format(value, context: inputs)))
                } catch let error as FormulaError {
                    return .failure(error)
                }
            }
        } catch let error as FormulaError {
            return .failure(error)
        } catch {
            return .failure(FormulaError("Строка не прочиталась: \(error.localizedDescription)"))
        }
    }
}

extension FormulaType {
    /// Тип итога в настройках свойства (`config.resultType`): фильтр, сортировка и показ — как у свойства того же типа.
    public var configValue: String {
        switch self {
        case .number: "number"
        case .text: "text"
        case .bool: "checkbox"
        case .date: "date"
        case .page: "page"
        case .list: "list"
        case .any: "unknown"
        }
    }
}
