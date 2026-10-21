import Foundation
import NotesCore

/// Флажок: `true` / `false`; пусто — не отмечен.
struct CheckboxType: PropertyType {
    let kind = PropertyKind.checkbox
    var filterOperators: [FilterOperator] { [.is] }
    var calculations: [Calculation] { Calculation.common + Calculation.checkbox }

    func comparables(_ value: JSONValue, in context: PropertyContext) -> CellComparables {
        CellComparables(sortNumber: value.bool == true ? 1 : 0)
    }
    func displayText(_ value: JSONValue?, in context: PropertyContext) -> String { value?.bool == true ? "Yes" : "No" }
    func csvText(_ value: JSONValue?, in context: PropertyContext) -> String { displayText(value, in: context) }
    func parseCSV(_ text: String, in context: PropertyContext) -> CSVValue { .value(.bool(Self.isChecked(text))) }

    /// `Yes`, `true`, `1`, `да`, ненулевое число — отмечен (contracts/property-types.md, «Смена типа»).
    static func isChecked(_ text: String) -> Bool {
        let word = text.trimmingCharacters(in: .whitespaces).lowercased()
        if ["yes", "true", "да", "✓", "x"].contains(word) { return true }
        return NumberType.parse(word).map { $0 != 0 } ?? false
    }

    func groupKeys(_ value: JSONValue?, in context: PropertyContext, bucket: JSONValue?) -> [String] {
        [value?.bool == true ? "checked" : "unchecked"]
    }
}
