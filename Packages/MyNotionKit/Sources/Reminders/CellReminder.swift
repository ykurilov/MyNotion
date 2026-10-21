import Foundation
import NotesCore

/// Напоминание ячейки «Даты» (research R16, contracts/property-types.md, «Дата: форматы и напоминания»): без времени —
/// в 9:00 дня события или за 1, 2, 7 дней; со временем — в момент события или за 5, 10, 15, 30 минут, 1, 2 часа, 1, 2 дня.
public enum CellReminder {
    static let namespace = UUID(uuidString: "6F1C4D52-5A0E-4E59-9B0A-2A7D4C0B0016")!

    /// id напоминания ячейки — он же id уведомления и отметки «сделано».
    public static func mentionId(rowId: UUID, propertyId: UUID) -> UUID { .derived(namespace, rowId, propertyId) }

    public static func fireAt(_ value: JSONValue?) -> Date? {
        guard let value, let kind = value["reminder"]?.string, let text = value["start"]?.string else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = value["timeZone"]?.string.flatMap(TimeZone.init(identifier:)) ?? .current
        let parts = text.split(whereSeparator: { $0 == "-" || $0 == "T" || $0 == ":" }).compactMap { Int($0) }
        guard parts.count >= 3, let start = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2],
                                                                               hour: parts.count > 3 ? parts[3] : 0,
                                                                               minute: parts.count > 4 ? parts[4] : 0)) else { return nil }
        let hasTime = value["hasTime"]?.bool ?? false
        func atNine(daysBefore: Int) -> Date? {
            calendar.date(byAdding: .day, value: -daysBefore, to: calendar.date(bySettingHour: 9, minute: 0, second: 0, of: start)!)
        }
        switch kind {
        case "day0At9": return atNine(daysBefore: 0)
        case "week1": return atNine(daysBefore: 7)
        case "day1": return hasTime ? calendar.date(byAdding: .day, value: -1, to: start) : atNine(daysBefore: 1)
        case "day2": return hasTime ? calendar.date(byAdding: .day, value: -2, to: start) : atNine(daysBefore: 2)
        case "atTime": return start
        case "minutes5": return start.addingTimeInterval(-300)
        case "minutes10": return start.addingTimeInterval(-600)
        case "minutes15": return start.addingTimeInterval(-900)
        case "minutes30": return start.addingTimeInterval(-1_800)
        case "hour1": return start.addingTimeInterval(-3_600)
        case "hour2": return start.addingTimeInterval(-7_200)
        default: return nil
        }
    }
}
