import Foundation
import NotesCore

/// Что показать в ячейке (contracts/property-types.md, «Значения и показ»): текст, плашки вариантов, флажок.
public enum CellPresentation: Sendable, Hashable {
    case empty
    case text(String)
    /// Плашки вариантов и связей: название и цвет Notion.
    case chips([Chip])
    case checkbox(Bool)

    public struct Chip: Sendable, Hashable {
        public var title: String
        public var color: OptionColor
    }

    /// Текст показа (поиск, буфер, CSV-подобный вид).
    public var plainText: String {
        switch self {
        case .empty: ""
        case .text(let text): text
        case .chips(let chips): chips.map(\.title).joined(separator: ", ")
        case .checkbox(let checked): checked ? "Yes" : "No"
        }
    }
}

/// Показ значения по типу свойства: текст — от модели типа, варианты и связи — плашками, флажок — квадратом.
public enum CellPresenter {
    public static func present(_ property: DatabaseProperty, in row: RowSnapshot, context: PropertyContext) -> CellPresentation {
        let type = PropertyTypes.type(for: property.kind)
        switch property.kind {
        case .title: return row.title.isEmpty ? .empty : .text(row.title)
        case .createdTime: return .text(type.displayText(PropertyValue.pageDate(row.createdAt, in: context), in: context))
        case .lastEditedTime: return .text(type.displayText(PropertyValue.pageDate(row.updatedAt, in: context), in: context))
        case .relation:
            let related = row.relations[property.id] ?? []
            return related.isEmpty ? .empty : .chips(related.map { CellPresentation.Chip(title: $0.title.isEmpty ? Page.untitledTitle : $0.title, color: .default) })
        case .formula, .rollup:
            guard let value = row.computed[property.id] else { return .empty }
            if case .bool(let flag) = value { return .checkbox(flag) }
            let text = type.displayText(value, in: context)
            return text.isEmpty ? .empty : .text(text)
        case .select, .status:
            guard let option = context.option(row.cells[property.id])?.option else { return .empty }
            return .chips([CellPresentation.Chip(title: option.name, color: option.optionColor)])
        case .multiSelect:
            let chips = (row.cells[property.id]?.array ?? []).compactMap { context.option($0)?.option }
                .map { CellPresentation.Chip(title: $0.name, color: $0.optionColor) }
            return chips.isEmpty ? .empty : .chips(chips)
        case .checkbox: return .checkbox(row.cells[property.id]?.bool ?? false)
        case .files:
            let names = FilesType.names(row.cells[property.id])
            return names.isEmpty ? .empty : .chips(names.map { CellPresentation.Chip(title: $0, color: .default) })
        default:
            guard let value = row.cells[property.id] else { return .empty }
            let text = type.displayText(value, in: context)
            return text.isEmpty ? .empty : .text(text)
        }
    }
}

/// Разбор дат значений: `2026-10-21` или `2026-10-21T15:30[:05]` в поясе значения.
public enum DateText {
    private static let lock = NSLock()

    /// `2026-10-21` или `2026-10-21T15:30` в поясе значения.
    public static func parse(_ text: String, timeZone: String?) -> Date? {
        var parts: [Int] = []
        parts.reserveCapacity(5)
        var current = 0, hasDigits = false
        for byte in text.utf8 {
            if byte >= 48, byte <= 57 { current = current * 10 + Int(byte - 48); hasDigits = true }
            else if hasDigits { parts.append(current); current = 0; hasDigits = false }
        }
        if hasDigits { parts.append(current) }
        guard parts.count >= 3 else { return nil }
        return calendar(timeZone).date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2],
                                                            hour: parts.count > 3 ? parts[3] : 0, minute: parts.count > 4 ? parts[4] : 0,
                                                            second: parts.count > 5 ? parts[5] : 0))
    }

    nonisolated(unsafe) private static var calendars: [String: Calendar] = [:]

    /// Григорианский календарь пояса — один на пояс (создание календаря дороже самого разбора даты).
    static func calendar(_ timeZone: String?) -> Calendar {
        lock.lock()
        defer { lock.unlock() }
        let key = timeZone ?? ""
        if let calendar = calendars[key] { return calendar }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone.flatMap(TimeZone.init(identifier:)) ?? .current
        calendars[key] = calendar
        return calendar
    }
}
