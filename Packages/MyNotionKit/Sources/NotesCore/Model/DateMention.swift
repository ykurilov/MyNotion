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
    /// «@сегодня» или «@сейчас», вставленные в странице-шаблоне (003): в копии шаблона дата становится моментом создания.
    public var templateRelative: TemplateRelative?
    /// Ключи от более новой версии: переносятся при записи, как неизвестные ключи `props`.
    public var unknownKeys: [String: JSONValue] = [:]

    public enum TemplateRelative: String, Sendable, Hashable, Codable {
        case today
        case now
    }

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

    public init(id: UUID = .timeOrdered(), start: String, includesTime: Bool, timeZone: String, reminder: Reminder? = nil,
                templateRelative: TemplateRelative? = nil) {
        self.id = id
        self.start = start
        self.includesTime = includesTime
        self.timeZone = timeZone
        self.reminder = reminder
        self.templateRelative = templateRelative
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case id, start, includesTime, timeZone, reminder, templateRelative }

    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        start = try container.decode(String.self, forKey: .start)
        includesTime = try container.decode(Bool.self, forKey: .includesTime)
        timeZone = try container.decode(String.self, forKey: .timeZone)
        reminder = try container.decodeIfPresent(Reminder.self, forKey: .reminder)
        // Незнакомое значение (от более новой версии) не ломает дату: остаётся среди неизвестных ключей.
        templateRelative = try? container.decodeIfPresent(TemplateRelative.self, forKey: .templateRelative)
        let known = Set(CodingKeys.allCases.map(\.rawValue))
        let all = try decoder.container(keyedBy: AnyKey.self)
        for key in all.allKeys where !known.contains(key.stringValue) {
            unknownKeys[key.stringValue] = try all.decode(JSONValue.self, forKey: key)
        }
        if templateRelative == nil, container.contains(.templateRelative) {
            unknownKeys[CodingKeys.templateRelative.rawValue] = try all.decode(JSONValue.self, forKey: AnyKey(stringValue: "templateRelative"))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var all = encoder.container(keyedBy: AnyKey.self)
        for (key, value) in unknownKeys { try all.encode(value, forKey: AnyKey(stringValue: key)) }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(start, forKey: .start)
        try container.encode(includesTime, forKey: .includesTime)
        try container.encode(timeZone, forKey: .timeZone)
        try container.encodeIfPresent(reminder, forKey: .reminder)
        try container.encodeIfPresent(templateRelative, forKey: .templateRelative)
    }
}
