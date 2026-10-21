import Foundation
import NotesCore

/// Название: значение — `Page.title` строки (ячейки нет, data-model.md).
struct TitleType: PropertyType {
    let kind = PropertyKind.title
    var filterOperators: [FilterOperator] { FilterOperator.textOperators }

    func comparables(_ value: JSONValue, in context: PropertyContext) -> CellComparables { TextComparables.of(value.string ?? "") }
    func displayText(_ value: JSONValue?, in context: PropertyContext) -> String {
        let title = value?.string ?? ""
        return title.isEmpty ? Page.untitledTitle : title
    }
    func csvText(_ value: JSONValue?, in context: PropertyContext) -> String { value?.string ?? "" }
    func parseCSV(_ text: String, in context: PropertyContext) -> CSVValue { .value(.string(text)) }
    func groupKeys(_ value: JSONValue?, in context: PropertyContext, bucket: JSONValue?) -> [String] {
        let title = value?.string ?? ""
        return title.isEmpty ? [] : [SortableText.make(title)]
    }
}
