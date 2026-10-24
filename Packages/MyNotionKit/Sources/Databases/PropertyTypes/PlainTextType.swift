import Foundation
import NotesCore

/// Ссылка, email, телефон: значение — текст как есть. У телефона поиск находит и цифры подряд.
struct PlainTextType: PropertyType {
    let kind: PropertyKind
    var filterOperators: [FilterOperator] { FilterOperator.textOperators }

    func comparables(_ value: JSONValue, in context: PropertyContext) -> CellComparables {
        let text = value.string ?? ""
        let digits = kind == .phone ? text.filter(\.isNumber) : nil
        return TextComparables.of(text, extraSearch: digits.flatMap { $0.isEmpty ? nil : $0 })
    }
    func displayText(_ value: JSONValue?, in context: PropertyContext) -> String { value?.string ?? "" }
    func csvText(_ value: JSONValue?, in context: PropertyContext) -> String { value?.string ?? "" }
    func parseCSV(_ text: String, in context: PropertyContext) -> CSVValue {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return .value(trimmed.isEmpty ? nil : .string(trimmed))
    }
    func groupKeys(_ value: JSONValue?, in context: PropertyContext, bucket: JSONValue?) -> [String] {
        (value?.string).flatMap { $0.isEmpty ? nil : [SortableText.make($0)] } ?? []
    }
}
