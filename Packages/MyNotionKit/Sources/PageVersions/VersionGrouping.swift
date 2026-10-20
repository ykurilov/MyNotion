import Foundation

/// Шаг группировки списка истории (contracts/pages-ui.md, «История версий»): в каждом отрезке видна последняя версия.
public enum VersionGrouping: Int, Sendable, CaseIterable, Identifiable {
    case minute = 1
    case quarterHour = 15
    case hour = 60

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .minute: "1 минута"
        case .quarterHour: "15 минут"
        case .hour: "1 час"
        }
    }

    /// На кнопке «Группировать: 1 мин ▾».
    public var shortTitle: String {
        switch self {
        case .minute: "1 мин"
        case .quarterHour: "15 мин"
        case .hour: "1 ч"
        }
    }

    /// Версии новыми первыми → по одной на отрезок (последняя в нём), тот же порядок.
    public func group(_ versions: [PageVersionInfo], calendar: Calendar = .current) -> [PageVersionInfo] {
        var seen: Set<Date> = []
        return versions.filter { seen.insert(bucket(of: $0.createdAt, calendar: calendar)).inserted }
    }

    private func bucket(of date: Date, calendar: Calendar) -> Date {
        guard let hour = calendar.dateInterval(of: .hour, for: date)?.start else { return date }
        let minutes = Int(date.timeIntervalSince(hour) / 60)
        return hour.addingTimeInterval(Double(minutes - minutes % rawValue) * 60)
    }
}
