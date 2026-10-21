import Foundation

extension FormulaFunctions {
    /// `prop("id")` своей строки и `страница.prop("id")` строки из связи.
    static let pages: [String: FormulaFunction] = [
        "prop": .eager { arguments, evaluator in
            switch arguments.count {
            case 1:
                guard let id = arguments[0].text else { throw FormulaError("prop ждёт название свойства") }
                return evaluator.context.value(ofProperty: id, row: evaluator.rowId)
            case 2:
                guard case .page(let row) = arguments[0], let id = arguments[1].text else { return .empty }
                return evaluator.context.value(ofProperty: id, row: row)
            default: throw FormulaError("prop ждёт одно название свойства")
            }
        },
        "id": .eager { arguments, evaluator in
            if case .page(let row)? = arguments.first { return .text(row.uuidString.lowercased().replacingOccurrences(of: "-", with: "")) }
            return .text(evaluator.rowId.uuidString.lowercased().replacingOccurrences(of: "-", with: ""))
        },
    ]
}
