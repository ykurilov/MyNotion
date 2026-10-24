import Foundation
import NotesCore

/// Множественный выбор: значение — список id. `sortText` — id через пробел (условие «содержит» по индексу),
/// `sortNumber` — место первого варианта (сортировка «по первому», как у Notion).
struct MultiSelectType: PropertyType {
    let kind = PropertyKind.multiSelect
    var filterOperators: [FilterOperator] { [.contains, .doesNotContain, .isEmpty, .isNotEmpty] }

    private func options(_ value: JSONValue?, in context: PropertyContext) -> [(option: SelectOption, position: Int)] {
        (value?.array ?? []).compactMap { context.option($0) }
    }

    func comparables(_ value: JSONValue, in context: PropertyContext) -> CellComparables {
        let chosen = options(value, in: context)
        guard let first = chosen.first else { return CellComparables() }
        return CellComparables(sortText: chosen.map { $0.option.id.uuidString.lowercased() }.joined(separator: " "),
                               sortNumber: Double(first.position),
                               searchText: chosen.map { SortableText.make($0.option.name) }.joined(separator: " "))
    }

    func displayText(_ value: JSONValue?, in context: PropertyContext) -> String {
        options(value, in: context).map(\.option.name).joined(separator: ", ")
    }
    func csvText(_ value: JSONValue?, in context: PropertyContext) -> String { displayText(value, in: context) }

    func parseCSV(_ text: String, in context: PropertyContext) -> CSVValue {
        let names = text.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !names.isEmpty else { return .value(nil) }
        let found = names.compactMap { context.option(named: $0) }
        guard found.count == names.count else { return .options(names) }
        return .value(.array(found.map { .string($0.id.uuidString.lowercased()) }))
    }

    func groupKeys(_ value: JSONValue?, in context: PropertyContext, bucket: JSONValue?) -> [String] {
        options(value, in: context).map { $0.option.id.uuidString.lowercased() }
    }
}
