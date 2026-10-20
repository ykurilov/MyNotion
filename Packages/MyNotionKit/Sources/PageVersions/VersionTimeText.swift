import Foundation

/// Время версии в списке и в шапке просмотра: «Сегодня в 18:25», «Вчера в 9:05», «19 октября в 18:25»,
/// прошлый год — «19 октября 2025 в 18:25».
public enum VersionTimeText {
    static let months = ["января", "февраля", "марта", "апреля", "мая", "июня", "июля", "августа", "сентября", "октября", "ноября", "декабря"]

    /// То же время посреди фразы: «к сегодня в 15:03», «к вчера в 9:00» — со строчной.
    public static func inSentence(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let text = text(for: date, now: now, calendar: calendar)
        return text.prefix(1).lowercased() + text.dropFirst()
    }

    public static func text(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let time = String(format: "%d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day
        switch days {
        case 0: return "Сегодня в \(time)"
        case -1: return "Вчера в \(time)"
        default:
            let day = "\(parts.day ?? 1) \(months[max((parts.month ?? 1) - 1, 0)])"
            let year = parts.year == calendar.component(.year, from: now) ? "" : " \(parts.year ?? 0)"
            return "\(day)\(year) в \(time)"
        }
    }
}
