import Foundation
import NotesCore

/// Сводка: итог из `db_computed`, как у формулы (`ComputedType`); у вычислений-процентов число — доля 0…1, показ —
/// «50%», как у Notion.
struct RollupType: PropertyType {
    let kind = PropertyKind.rollup
    private let computed = ComputedType(kind: .rollup)
    static let percentCalculations: Set<Calculation> = [.percentEmpty, .percentNotEmpty, .percentChecked, .percentUnchecked]

    var isEditable: Bool { false }
    var filterOperators: [FilterOperator] { computed.filterOperators }
    var calculations: [Calculation] { computed.calculations }

    private func percent(_ value: JSONValue?, in context: PropertyContext) -> Double? {
        guard let calculation = context.config["calculation"]?.string.flatMap(Calculation.init(rawValue:)),
              Self.percentCalculations.contains(calculation), case .number(let number)? = value else { return nil }
        return number
    }

    func comparables(_ value: JSONValue, in context: PropertyContext) -> CellComparables { computed.comparables(value, in: context) }

    func displayText(_ value: JSONValue?, in context: PropertyContext) -> String {
        guard let number = percent(value, in: context) else { return computed.displayText(value, in: context) }
        return NumberType.format(number, config: ["format": "percent"], locale: context.locale)
    }

    func csvText(_ value: JSONValue?, in context: PropertyContext) -> String {
        guard let number = percent(value, in: context) else { return computed.csvText(value, in: context) }
        return NumberType.plain((number * 100 * 1e9).rounded() / 1e9) + "%"
    }

    func parseCSV(_ text: String, in context: PropertyContext) -> CSVValue { computed.parseCSV(text, in: context) }

    func groupKeys(_ value: JSONValue?, in context: PropertyContext, bucket: JSONValue?) -> [String] {
        computed.groupKeys(value, in: context, bucket: bucket)
    }
}
