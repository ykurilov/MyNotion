import Foundation
import NotesCore

/// Текст: значение — `InlineText` 002 (`{runs, string}`).
struct TextType: PropertyType {
    let kind = PropertyKind.text
    var filterOperators: [FilterOperator] { FilterOperator.textOperators }

    static func string(_ value: JSONValue?) -> String { value?["string"]?.string ?? value?.string ?? "" }

    func comparables(_ value: JSONValue, in context: PropertyContext) -> CellComparables {
        TextComparables.of(Self.string(value))
    }

    func displayText(_ value: JSONValue?, in context: PropertyContext) -> String { Self.string(value) }
    func csvText(_ value: JSONValue?, in context: PropertyContext) -> String { Self.string(value) }

    func parseCSV(_ text: String, in context: PropertyContext) -> CSVValue {
        text.isEmpty ? .value(nil) : .value(["runs": [], "string": .string(text)])
    }

    func groupKeys(_ value: JSONValue?, in context: PropertyContext, bucket: JSONValue?) -> [String] {
        let text = Self.string(value)
        return text.isEmpty ? [] : [SortableText.make(text)]
    }
}

/// Сравнимые колонки текста: пустой — без колонок.
enum TextComparables {
    static func of(_ text: String, extraSearch: String? = nil) -> CellComparables {
        guard !text.isEmpty else { return CellComparables() }
        let sortable = SortableText.make(text)
        return CellComparables(sortText: sortable, searchText: extraSearch.map { sortable + " " + $0 } ?? sortable)
    }
}
