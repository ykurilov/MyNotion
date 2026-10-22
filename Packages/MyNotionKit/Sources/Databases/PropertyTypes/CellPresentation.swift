import Foundation
import NotesCore

/// Что показать в ячейке (contracts/property-types.md, «Значения и показ»): текст, плашки вариантов, флажок.
public enum CellPresentation: Sendable, Hashable {
    case empty
    case text(String)
    /// Плашки вариантов и связей: название и цвет Notion.
    case chips([Chip])
    case checkbox(Bool)
    /// Число полосой или кольцом (US2, «Показывать как»).
    case meter(NumberMeter)

    public struct Chip: Sendable, Hashable {
        public var title: String
        public var color: OptionColor
        /// Плашка статуса — со скруглением в полвысоты и точкой цвета (Notion 7.39).
        public var showsDot = false
        /// Картинка из ячейки «Файлы и медиа» — уменьшенной копией вместо плашки.
        public var thumbnailId: UUID? = nil
    }

    /// Число в виде полосы или кольца: доля заполнения (0…1), цвет Notion и текст числа (`nil` — «Показывать число» выкл).
    public struct NumberMeter: Sendable, Hashable {
        public var fraction: Double
        public var color: OptionColor
        public var isRing: Bool
        public var text: String?
    }

    /// Текст показа (поиск, буфер, CSV-подобный вид).
    public var plainText: String {
        switch self {
        case .empty: ""
        case .text(let text): text
        case .chips(let chips): chips.map(\.title).joined(separator: ", ")
        case .checkbox(let checked): checked ? "Yes" : "No"
        case .meter(let meter): meter.text ?? ""
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
            // Список страниц из связи — плашками, как у связи.
            if let items = value.array, !items.isEmpty, items.allSatisfy({ $0["id"] != nil }) {
                return .chips(items.map { CellPresentation.Chip(title: ($0["title"]?.string).flatMap { $0.isEmpty ? nil : $0 } ?? Page.untitledTitle, color: .default) })
            }
            let text = type.displayText(value, in: context)
            return text.isEmpty ? .empty : .text(text)
        case .select, .status:
            guard let option = context.option(row.cells[property.id])?.option else { return .empty }
            return .chips([CellPresentation.Chip(title: option.name, color: option.optionColor, showsDot: property.kind == .status)])
        case .multiSelect:
            let chips = (row.cells[property.id]?.array ?? []).compactMap { context.option($0)?.option }
                .map { CellPresentation.Chip(title: $0.name, color: $0.optionColor) }
            return chips.isEmpty ? .empty : .chips(chips)
        case .checkbox: return .checkbox(row.cells[property.id]?.bool ?? false)
        case .files:
            let items = FilesValue.items(row.cells[property.id])
            return items.isEmpty ? .empty : .chips(items.map { item in
                var chip = CellPresentation.Chip(title: item.name, color: .default)
                if FilesValue.isImage(item), case .file(let ref) = item { chip.thumbnailId = ref.id }
                return chip
            })
        case .number:
            guard let number = row.cells[property.id]?.number else { return .empty }
            let text = type.displayText(row.cells[property.id], in: context)
            if let meter = NumberDisplay.meter(number, text: text, config: context.config) { return .meter(meter) }
            return .text(text)
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
