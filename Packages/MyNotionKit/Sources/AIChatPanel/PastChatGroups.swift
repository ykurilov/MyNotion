import Foundation

/// Прошлые чаты по срокам последнего сообщения: «Сегодня», «Вчера», «Последние 7 дней», «Последние 30 дней», «Раньше».
public enum PastChatGroups {
    public struct Item: Sendable, Hashable, Identifiable {
        public let id: UUID
        public let title: String
        public let updatedAt: Date

        public init(id: UUID, title: String, updatedAt: Date) {
            self.id = id
            self.title = title
            self.updatedAt = updatedAt
        }
    }

    public struct Group: Sendable, Hashable, Identifiable {
        public let title: String
        public let items: [Item]
        public var id: String { title }
    }

    /// `items` — свежие сверху; `query` — поиск по названию без учёта регистра.
    public static func make(_ items: [Item], query: String, now: Date = Date(), calendar: Calendar = .current) -> [Group] {
        let query = query.trimmingCharacters(in: .whitespaces)
        let found = query.isEmpty ? items : items.filter { $0.title.localizedCaseInsensitiveContains(query) }
        let today = calendar.startOfDay(for: now)
        let bounds: [(String, Date)] = [
            ("Сегодня", today),
            ("Вчера", calendar.date(byAdding: .day, value: -1, to: today) ?? today),
            ("Последние 7 дней", calendar.date(byAdding: .day, value: -7, to: today) ?? today),
            ("Последние 30 дней", calendar.date(byAdding: .day, value: -30, to: today) ?? today),
        ]
        var groups: [(String, [Item])] = bounds.map { ($0.0, []) } + [("Раньше", [])]
        for item in found {
            let index = bounds.firstIndex { item.updatedAt >= $0.1 } ?? bounds.count
            groups[index].1.append(item)
        }
        return groups.filter { !$0.1.isEmpty }.map { Group(title: $0.0, items: $0.1) }
    }
}
