import Foundation

/// Что показать в значке синхронизации на iPhone: состояние, подробности словами и когда всё сошлось последний раз.
public struct PhoneSyncBadge: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case ready
        case sending
        case error
    }

    public var kind: Kind
    public var detail: String
    public var lastSyncedAt: Date?

    public init(kind: Kind, detail: String, lastSyncedAt: Date? = nil) {
        self.kind = kind
        self.detail = detail
        self.lastSyncedAt = lastSyncedAt
    }

    /// Те же слова, что у значка на Mac.
    public var title: String {
        switch kind {
        case .ready: "Синхронизировано"
        case .sending: "Отправка…"
        case .error: "Ошибка синхронизации"
        }
    }

    /// Имя значка SF Symbols.
    public var symbol: String {
        switch kind {
        case .ready: "checkmark.icloud"
        case .sending: "arrow.triangle.2.circlepath.icloud"
        case .error: "exclamationmark.icloud"
        }
    }

    /// «Синхронизировано 5 минут назад», «… сегодня в 9:40», «… вчера в 23:10», «… 3 марта в 12:00».
    public func lastSyncedText(now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let lastSyncedAt else { return "Ещё не синхронизировано" }
        let seconds = now.timeIntervalSince(lastSyncedAt)
        if seconds < 60 { return "Синхронизировано только что" }
        if seconds < 3_600 {
            let minutes = Int(seconds / 60)
            return "Синхронизировано \(minutes) \(Self.minuteWord(minutes)) назад"
        }
        let time = Self.format(lastSyncedAt, "H:mm", calendar: calendar)
        if calendar.isDate(lastSyncedAt, inSameDayAs: now) { return "Синхронизировано сегодня в \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(lastSyncedAt, inSameDayAs: yesterday) {
            return "Синхронизировано вчера в \(time)"
        }
        return "Синхронизировано \(Self.format(lastSyncedAt, "d MMMM", calendar: calendar)) в \(time)"
    }

    private static func format(_ date: Date, _ pattern: String, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    private static func minuteWord(_ count: Int) -> String {
        let lastTwo = count % 100, last = count % 10
        if (11...14).contains(lastTwo) { return "минут" }
        switch last {
        case 1: return "минуту"
        case 2...4: return "минуты"
        default: return "минут"
        }
    }
}
