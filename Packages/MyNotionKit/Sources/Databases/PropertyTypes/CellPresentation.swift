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

/// Показ значения по типу свойства.
public enum CellPresenter {
    public static func present(_ property: DatabaseProperty, in row: RowSnapshot, catalog: DatabaseCatalog) -> CellPresentation {
        switch property.kind {
        case .title: return row.title.isEmpty ? .empty : .text(row.title)
        case .createdTime: return .text(DateText.format(row.createdAt, hasTime: true, config: property.config))
        case .lastEditedTime: return .text(DateText.format(row.updatedAt, hasTime: true, config: property.config))
        case .relation:
            let related = row.relations[property.id] ?? []
            return related.isEmpty ? .empty : .chips(related.map { CellPresentation.Chip(title: $0.title.isEmpty ? Page.untitledTitle : $0.title, color: .default) })
        case .formula, .rollup:
            guard let value = row.computed[property.id] else { return .empty }
            return presentComputed(value, property: property)
        default:
            guard let value = row.cells[property.id] else {
                return property.kind == .checkbox ? .checkbox(false) : .empty
            }
            return present(value, property: property, catalog: catalog)
        }
    }

    static func present(_ value: JSONValue, property: DatabaseProperty, catalog: DatabaseCatalog) -> CellPresentation {
        switch property.kind {
        case .text: return value["string"]?.string.map(CellPresentation.text) ?? .empty
        case .number: return value.number.map { .text(NumberText.format($0, config: property.config)) } ?? .empty
        case .select, .status:
            guard let id = value.string.flatMap(UUID.init(uuidString:)), let option = catalog.optionsById[id] else { return .empty }
            return .chips([CellPresentation.Chip(title: option.name, color: option.optionColor)])
        case .multiSelect:
            let chips = (value.array ?? []).compactMap { $0.string.flatMap(UUID.init(uuidString:)).flatMap { catalog.optionsById[$0] } }
                .map { CellPresentation.Chip(title: $0.name, color: $0.optionColor) }
            return chips.isEmpty ? .empty : .chips(chips)
        case .date: return DateText.formatValue(value, config: property.config).map(CellPresentation.text) ?? .empty
        case .checkbox: return .checkbox(value.bool ?? false)
        case .url, .email, .phone: return value.string.map(CellPresentation.text) ?? .empty
        case .files:
            let names = (value.array ?? []).compactMap { $0["name"]?.string ?? $0["attachment"]?["name"]?.string }
            return names.isEmpty ? .empty : .chips(names.map { CellPresentation.Chip(title: $0, color: .default) })
        case .uniqueId:
            guard let number = value.number else { return .empty }
            let prefix = property.config["prefix"]?.string ?? ""
            return .text(prefix.isEmpty ? "\(Int(number))" : "\(prefix)-\(Int(number))")
        default: return .empty
        }
    }

    static func presentComputed(_ value: JSONValue, property: DatabaseProperty) -> CellPresentation {
        switch value {
        case .number(let number): return .text(NumberText.format(number, config: property.config["numberFormat"] ?? .emptyObject))
        case .string(let text): return .text(text)
        case .bool(let checked): return .checkbox(checked)
        case .array(let items):
            let texts = items.compactMap { $0.string ?? $0.number.map { NumberText.format($0, config: .emptyObject) } }
            return texts.isEmpty ? .empty : .text(texts.joined(separator: ", "))
        case .object:
            return DateText.formatValue(value, config: property.config["dateFormat"].map { ["dateFormat": $0] } ?? .emptyObject)
                .map(CellPresentation.text) ?? .empty
        default: return .empty
        }
    }
}

/// Числа по формату свойства (черновик этапа 0: `number`, `numberWithSeparators`, `percent`; валюты — US2).
public enum NumberText {
    public static func format(_ number: Double, config: JSONValue) -> String {
        let decimals = config["decimals"]?.number.map(Int.init)
        let style = config["format"]?.string ?? "number"
        var value = number
        var suffix = ""
        if style == "percent" { value *= 100; suffix = "%" }
        let text: String
        if let decimals {
            text = String(format: "%.\(decimals)f", value)
        } else if value.rounded() == value, abs(value) < 1e15 {
            text = String(Int64(value))
        } else {
            text = String(value)
        }
        return text + suffix
    }
}

/// Даты по формату свойства (contracts/property-types.md, «Дата: форматы»): черновик этапа 0 — «Полный» и время 24 часа.
public enum DateText {
    nonisolated(unsafe) private static let full: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("d MMMM y")
        return formatter
    }()

    nonisolated(unsafe) private static let fullWithTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("d MMMM y HH:mm")
        return formatter
    }()

    private static let lock = NSLock()

    public static func format(_ date: Date, hasTime: Bool, config: JSONValue) -> String {
        lock.lock()
        defer { lock.unlock() }
        return (hasTime && config["timeFormat"]?.string != "hidden" ? fullWithTime : full).string(from: date)
    }

    /// Значение даты `{start, end?, hasTime, timeZone?}`.
    public static func formatValue(_ value: JSONValue, config: JSONValue) -> String? {
        guard let start = value["start"]?.string.flatMap({ parse($0, timeZone: value["timeZone"]?.string) }) else { return nil }
        let hasTime = value["hasTime"]?.bool ?? false
        var text = format(start, hasTime: hasTime, config: config)
        if let end = value["end"]?.string.flatMap({ parse($0, timeZone: value["timeZone"]?.string) }) {
            text += " → " + format(end, hasTime: hasTime, config: config)
        }
        return text
    }

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
                                                            hour: parts.count > 3 ? parts[3] : 0, minute: parts.count > 4 ? parts[4] : 0))
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
