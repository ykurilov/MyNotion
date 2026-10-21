import Foundation
import NotesCore

/// Выбор: значение — id варианта. `sortText` — id (фильтр «равно» по индексу), `sortNumber` — место в списке
/// (сортировка как у Notion), поиск — название. Вариант удалён или ещё не пришёл — пусто.
struct SelectType: PropertyType {
    let kind = PropertyKind.select
    var filterOperators: [FilterOperator] { [.is, .isNot, .isEmpty, .isNotEmpty] }

    func comparables(_ value: JSONValue, in context: PropertyContext) -> CellComparables {
        OptionValues.comparables(value, in: context)
    }
    func displayText(_ value: JSONValue?, in context: PropertyContext) -> String { context.option(value)?.option.name ?? "" }
    func csvText(_ value: JSONValue?, in context: PropertyContext) -> String { displayText(value, in: context) }
    func parseCSV(_ text: String, in context: PropertyContext) -> CSVValue { OptionValues.parseSingle(text, in: context) }
    func groupKeys(_ value: JSONValue?, in context: PropertyContext, bucket: JSONValue?) -> [String] {
        context.option(value).map { [$0.option.id.uuidString.lowercased()] } ?? []
    }
}

/// Статус: выбор с группами «К выполнению», «В работе», «Завершено»; новые варианты — в «Не начато».
struct StatusType: PropertyType {
    let kind = PropertyKind.status
    var filterOperators: [FilterOperator] { [.is, .isNot, .isInGroup, .isEmpty, .isNotEmpty] }

    func comparables(_ value: JSONValue, in context: PropertyContext) -> CellComparables { OptionValues.comparables(value, in: context) }
    func displayText(_ value: JSONValue?, in context: PropertyContext) -> String { context.option(value)?.option.name ?? "" }
    func csvText(_ value: JSONValue?, in context: PropertyContext) -> String { displayText(value, in: context) }
    func parseCSV(_ text: String, in context: PropertyContext) -> CSVValue { OptionValues.parseSingle(text, in: context) }
    func groupKeys(_ value: JSONValue?, in context: PropertyContext, bucket: JSONValue?) -> [String] {
        guard let option = context.option(value)?.option else { return [] }
        // «По группам» — ключ группы статуса; иначе — вариант.
        if bucket?.string == "group" { return [option.statusGroup?.rawValue ?? StatusGroup.todo.rawValue] }
        return [option.id.uuidString.lowercased()]
    }
}

enum OptionValues {
    static func comparables(_ value: JSONValue, in context: PropertyContext) -> CellComparables {
        guard let (option, position) = context.option(value) else { return CellComparables() }
        return CellComparables(sortText: option.id.uuidString.lowercased(), sortNumber: Double(position), searchText: SortableText.make(option.name))
    }

    static func parseSingle(_ text: String, in context: PropertyContext) -> CSVValue {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .value(nil) }
        if let option = context.option(named: name) { return .value(.string(option.id.uuidString.lowercased())) }
        return .options([name])
    }
}
