import Foundation
import NotesCore

/// Файлы и медиа: `[{attachment: AttachmentRef} | {url, name}]`. Не группируется (как в Notion).
struct FilesType: PropertyType {
    let kind = PropertyKind.files
    var filterOperators: [FilterOperator] { [.isEmpty, .isNotEmpty] }
    var isGroupable: Bool { false }

    static func names(_ value: JSONValue?) -> [String] {
        (value?.array ?? []).compactMap { $0["name"]?.string ?? $0["attachment"]?["name"]?.string }
    }

    func comparables(_ value: JSONValue, in context: PropertyContext) -> CellComparables {
        let names = Self.names(value)
        guard let first = names.first else { return CellComparables() }
        return CellComparables(sortText: SortableText.make(first), sortNumber: Double(names.count),
                               searchText: names.map(SortableText.make).joined(separator: " "))
    }
    func displayText(_ value: JSONValue?, in context: PropertyContext) -> String { Self.names(value).joined(separator: ", ") }
    func csvText(_ value: JSONValue?, in context: PropertyContext) -> String { displayText(value, in: context) }

    func parseCSV(_ text: String, in context: PropertyContext) -> CSVValue {
        let items = text.components(separatedBy: ", ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !items.isEmpty else { return .value(nil) }
        return .value(.array(items.map { item in
            if let url = URL(string: item), url.scheme != nil {
                return ["url": .string(item), "name": .string(url.lastPathComponent.isEmpty ? item : url.lastPathComponent)]
            }
            return ["name": .string(item)]
        }))
    }

    func groupKeys(_ value: JSONValue?, in context: PropertyContext, bucket: JSONValue?) -> [String] { [] }
}
