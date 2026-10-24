import Foundation
import NotesCore

/// ID: номер строки, показ — «ПРЕФИКС-N» или «N»; выдаёт и чинит `UniqueIds` (research R9). Не группируется, не правится.
struct UniqueIdType: PropertyType {
    let kind = PropertyKind.uniqueId
    var filterOperators: [FilterOperator] { [.equals, .notEquals, .greaterThan, .lessThan, .greaterThanOrEqual, .lessThanOrEqual] }
    var isGroupable: Bool { false }
    var isEditable: Bool { false }

    private func prefix(_ context: PropertyContext) -> String { context.config["prefix"]?.string ?? "" }

    func comparables(_ value: JSONValue, in context: PropertyContext) -> CellComparables {
        guard let number = value.number else { return CellComparables() }
        let plain = NumberType.plain(number)
        let prefixed = prefix(context).isEmpty ? nil : SortableText.make("\(prefix(context))-\(plain)")
        return CellComparables(sortNumber: number, searchText: prefixed.map { "\($0) \(plain)" } ?? plain)
    }
    func displayText(_ value: JSONValue?, in context: PropertyContext) -> String {
        guard let number = value?.number else { return "" }
        return prefix(context).isEmpty ? NumberType.plain(number) : "\(prefix(context))-\(NumberType.plain(number))"
    }
    func csvText(_ value: JSONValue?, in context: PropertyContext) -> String { displayText(value, in: context) }
    func parseCSV(_ text: String, in context: PropertyContext) -> CSVValue {
        let digits = String(text.reversed().prefix { $0.isNumber }.reversed())
        return .value(Double(digits).map(JSONValue.number))
    }
    func groupKeys(_ value: JSONValue?, in context: PropertyContext, bucket: JSONValue?) -> [String] { [] }
}
