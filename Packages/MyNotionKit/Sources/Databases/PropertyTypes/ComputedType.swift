import Foundation
import NotesCore

/// Сводка и формула: итог из `db_computed`, тип — по итогу (число, текст, флажок, дата `{start…}`, список).
/// Правки нет; неизвестный тип свойства (от новой версии) ведёт себя так же.
struct ComputedType: PropertyType {
    let kind: PropertyKind
    var isEditable: Bool { false }
    var filterOperators: [FilterOperator] { FilterOperator.textOperators }
    var calculations: [Calculation] {
        (kind == .rollup ? Calculation.rollupOnly : []) + Calculation.common + Calculation.numeric + Calculation.dates
    }

    func comparables(_ value: JSONValue, in context: PropertyContext) -> CellComparables {
        switch value {
        case .number(let number): return CellComparables(sortNumber: number, searchText: NumberType.plain(number))
        case .string(let text): return TextComparables.of(text)
        case .bool(let flag): return CellComparables(sortNumber: flag ? 1 : 0)
        case .object: return DateValues.comparables(value)
        case .array(let items):
            let texts = items.map { item in item.string ?? item["title"]?.string ?? item.number.map(NumberType.plain) ?? "" }.filter { !$0.isEmpty }
            guard let first = texts.first else { return CellComparables() }
            return CellComparables(sortText: SortableText.make(first), searchText: texts.map(SortableText.make).joined(separator: " "))
        default: return CellComparables()
        }
    }

    func displayText(_ value: JSONValue?, in context: PropertyContext) -> String {
        switch value {
        case .number(let number)?:
            return NumberType.format(number, config: context.config["numberFormat"] ?? .emptyObject, locale: context.locale)
        case .object?: return DateValues.display(value, in: context)
        default: return csvText(value, in: context)
        }
    }

    func csvText(_ value: JSONValue?, in context: PropertyContext) -> String {
        switch value {
        case .number(let number)?: return NumberType.plain(number)
        case .string(let text)?: return text
        case .bool(let flag)?: return flag ? "Yes" : "No"
        case .object?: return DateValues.csv(value)
        case .array(let items)?: return items.map { csvText($0, in: context) }.joined(separator: ", ")
        default: return ""
        }
    }

    /// Итог не читается из CSV: формулы и сводки Notion приходят готовыми значениями (contracts, импорт) — текстом.
    func parseCSV(_ text: String, in context: PropertyContext) -> CSVValue { .value(text.isEmpty ? nil : .string(text)) }

    func groupKeys(_ value: JSONValue?, in context: PropertyContext, bucket: JSONValue?) -> [String] {
        switch value {
        case .object?: return DateValues.groupKeys(value, in: context, bucket: bucket?.string ?? "month")
        case .array(let items)?: return items.map { csvText($0, in: context) }.filter { !$0.isEmpty }
        case nil, .null?: return []
        default:
            let text = csvText(value, in: context)
            return text.isEmpty ? [] : [text]
        }
    }
}
