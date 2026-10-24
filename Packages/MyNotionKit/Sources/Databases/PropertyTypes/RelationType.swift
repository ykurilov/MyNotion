import Foundation
import NotesCore

/// Связь: значение для показа и выгрузки — `[{id, title, path?}]` из `db_relation_link` (своих ячеек нет).
/// Сортировка — по названию первой связанной строки; CSV — «Название (путь)».
struct RelationType: PropertyType {
    let kind = PropertyKind.relation
    var filterOperators: [FilterOperator] { [.contains, .doesNotContain, .isEmpty, .isNotEmpty] }
    var isEditable: Bool { true }

    private func titles(_ value: JSONValue?) -> [String] {
        (value?.array ?? []).map { $0["title"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? Page.untitledTitle }
    }

    func comparables(_ value: JSONValue, in context: PropertyContext) -> CellComparables {
        let titles = titles(value)
        guard let first = titles.first else { return CellComparables() }
        return CellComparables(sortText: SortableText.make(first), searchText: titles.map(SortableText.make).joined(separator: " "))
    }
    func displayText(_ value: JSONValue?, in context: PropertyContext) -> String { titles(value).joined(separator: ", ") }
    func csvText(_ value: JSONValue?, in context: PropertyContext) -> String {
        (value?.array ?? []).map { item in
            let title = item["title"]?.string ?? ""
            return item["path"]?.string.map { "\(title) (\($0))" } ?? title
        }.joined(separator: ", ")
    }
    /// Связи из CSV собирает импорт вторым проходом (research R18): здесь — только названия.
    func parseCSV(_ text: String, in context: PropertyContext) -> CSVValue {
        let titles = text.components(separatedBy: ", ").filter { !$0.isEmpty }
        return .value(titles.isEmpty ? nil : .array(titles.map { ["title": .string($0)] }))
    }
    func groupKeys(_ value: JSONValue?, in context: PropertyContext, bucket: JSONValue?) -> [String] {
        (value?.array ?? []).compactMap { $0["id"]?.string }
    }
}
