import Foundation

/// Дата в тексте блока (data-model.md, «Оформление в строке»): знак U+FFFC с оформлением `date`.
/// `id` — он же id напоминания и уведомления (research R11).
public struct DateMention: Sendable, Hashable, Codable {
    public var id: UUID
    /// Дата `2026-10-20` или дата-время `2026-10-20T09:00` (ISO 8601, без пояса — пояс в `timeZone`).
    public var start: String
    public var includesTime: Bool
    /// Пояс IANA, в котором дату создали.
    public var timeZone: String
    public var reminder: Reminder?

    public struct Reminder: Sendable, Hashable, Codable {
        /// Момент напоминания, UTC.
        public var fireAt: Date

        public init(fireAt: Date) {
            self.fireAt = fireAt
        }

        private enum CodingKeys: String, CodingKey { case fireAt }

        /// Момент — строкой ISO 8601 в UTC с точностью до секунды: в базе и в пачке одна и та же запись.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let text = try container.decode(String.self, forKey: .fireAt)
            guard let date = try? Date(text, strategy: .iso8601) else {
                throw DecodingError.dataCorruptedError(forKey: .fireAt, in: container, debugDescription: "Не дата ISO 8601: \(text)")
            }
            fireAt = date
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(fireAt.formatted(.iso8601), forKey: .fireAt)
        }
    }

    public init(id: UUID = .timeOrdered(), start: String, includesTime: Bool, timeZone: String, reminder: Reminder? = nil) {
        self.id = id
        self.start = start
        self.includesTime = includesTime
        self.timeZone = timeZone
        self.reminder = reminder
    }
}
