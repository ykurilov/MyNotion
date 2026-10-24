import Databases
import Foundation
import NotesCore

/// «Формула»: итог без правки (contracts/formulas.md, «Итог»). Показ — `CellPresenter`: число и дата — в формате
/// свойства (`numberFormat`, `dateFormat`), флажок — квадратом, список страниц — плашками, прочий список — через запятую,
/// ошибка вычисления и пусто — пустая ячейка. Текст для копирования и поиска — как показан.
struct FormulaCell: GridCellType {
    let kind = PropertyKind.formula

    func editingText(_ value: JSONValue?, context: PropertyContext) -> String {
        guard let value else { return "" }
        if case .bool(let flag) = value { return flag ? "true" : "false" }
        return PropertyTypes.type(for: .formula).displayText(value, in: context)
    }
}
