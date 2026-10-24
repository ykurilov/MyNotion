import Foundation
import NotesCore

/// Вычисление итога колонки и сводки (contracts/property-types.md, «Итоги колонки и вычисления сводки»).
public enum Calculation: String, Sendable, Hashable, CaseIterable, Codable {
    case showOriginal, showUnique
    case countAll, countValues, countUnique, countEmpty, countNotEmpty
    case percentEmpty, percentNotEmpty
    case sum, average, median, min, max, range
    case earliestDate, latestDate, dateRange
    case checked, unchecked, percentChecked, percentUnchecked

    public static let common: [Calculation] = [.countAll, .countValues, .countUnique, .countEmpty, .countNotEmpty, .percentEmpty, .percentNotEmpty]
    public static let numeric: [Calculation] = [.sum, .average, .median, .min, .max, .range]
    public static let dates: [Calculation] = [.earliestDate, .latestDate, .dateRange]
    public static let checkbox: [Calculation] = [.checked, .unchecked, .percentChecked, .percentUnchecked]
    /// Только у сводки.
    public static let rollupOnly: [Calculation] = [.showOriginal, .showUnique]
}

public enum Calculations {
    /// Итог по значениям строк (после фильтра и поиска). Проценты — доля 0…1; диапазон дат — в днях; `nil` — нечего считать.
    public static func compute(_ calculation: Calculation, values: [JSONValue?], in context: PropertyContext) -> JSONValue? {
        let present = values.compactMap { value -> JSONValue? in
            guard let value, value != .null else { return nil }
            if let items = value.array, items.isEmpty { return nil }
            if value == .bool(false), context.property.kind != .checkbox { return value }
            return value
        }
        // Списки (множественный выбор, файлы, связи, итоги-списки) считаются по элементам.
        let elements = present.flatMap { $0.array ?? [$0] }
        let filled = context.property.kind == .checkbox ? values.filter { $0?.bool == true }.count : present.count
        let total = Double(values.count)
        switch calculation {
        case .showOriginal: return .array(elements)
        case .showUnique: return .array(unique(elements))
        case .countAll: return .number(total)
        case .countValues: return .number(Double(elements.count))
        case .countUnique: return .number(Double(unique(elements).count))
        case .countEmpty: return .number(total - Double(filled))
        case .countNotEmpty: return .number(Double(filled))
        case .percentEmpty: return total == 0 ? nil : .number(rounded((total - Double(filled)) / total))
        case .percentNotEmpty: return total == 0 ? nil : .number(rounded(Double(filled) / total))
        case .sum, .average, .median, .min, .max, .range:
            let numbers = elements.compactMap(\.number).sorted()
            guard !numbers.isEmpty else { return nil }
            let sum = numbers.reduce(0, +)
            switch calculation {
            case .sum: return .number(sum)
            case .average: return .number(sum / Double(numbers.count))
            case .median:
                let middle = numbers.count / 2
                return .number(numbers.count % 2 == 1 ? numbers[middle] : (numbers[middle - 1] + numbers[middle]) / 2)
            case .min: return .number(numbers.first!)
            case .max: return .number(numbers.last!)
            default: return .number(numbers.last! - numbers.first!)
            }
        case .earliestDate, .latestDate, .dateRange:
            let dated = elements.compactMap { value in DateValues.start(value).map { (value, $0) } }.sorted { $0.1 < $1.1 }
            guard let first = dated.first, let last = dated.last else { return nil }
            switch calculation {
            case .earliestDate: return first.0
            case .latestDate: return last.0
            default:
                return .number(Double(context.calendar.dateComponents([.day], from: first.1, to: last.1).day ?? 0))
            }
        case .checked, .unchecked, .percentChecked, .percentUnchecked:
            let checked = Double(values.filter { $0?.bool == true }.count)
            switch calculation {
            case .checked: return .number(checked)
            case .unchecked: return .number(total - checked)
            case .percentChecked: return total == 0 ? nil : .number(rounded(checked / total))
            default: return total == 0 ? nil : .number(rounded((total - checked) / total))
            }
        }
    }

    private static func unique(_ values: [JSONValue]) -> [JSONValue] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0.jsonText).inserted }
    }

    private static func rounded(_ value: Double) -> Double { (value * 1e9).rounded() / 1e9 }
}
