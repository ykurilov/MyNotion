import Foundation
import GRDB
import NotesCore

/// Напоминание из индекса: где стоит дата и когда напомнить.
public struct ReminderEntry: Sendable, Hashable {
    public let mentionId: UUID
    public let pageId: UUID
    public let blockId: UUID
    public let fireAt: Date
    /// Показано на этом Mac или отдано системе показать в `fireAt`.
    public let deliveredAt: Date?
}

/// Чтение индекса напоминаний и отметки показа на этом Mac. Активное напоминание — в индексе и не сделано.
public struct ReminderIndex: Sendable {
    public let store: NotesStore

    public init(store: NotesStore) {
        self.store = store
    }

    /// Моменты в индексе — с точностью до секунды, как в записи даты (`DateMention.Reminder`).
    static func storedMoment(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    /// Несделанные напоминания с моментом в `range`, по порядку моментов.
    public func activeEntries(firingIn range: ClosedRange<Date>? = nil, after lowerBound: Date? = nil,
                              limit: Int? = nil) throws -> [ReminderEntry] {
        var conditions = ["(state.doneAt IS NULL)"]
        var arguments: [any DatabaseValueConvertible] = []
        if let range {
            conditions.append("idx.fireAt BETWEEN ? AND ?")
            arguments += [Self.storedMoment(range.lowerBound), Self.storedMoment(range.upperBound)]
        }
        if let lowerBound {
            conditions.append("idx.fireAt > ?")
            arguments.append(Self.storedMoment(lowerBound))
        }
        let sql = """
            SELECT idx.* FROM reminder_index idx LEFT JOIN reminder_state state ON state.mentionId = idx.mentionId
            WHERE \(conditions.joined(separator: " AND ")) ORDER BY idx.fireAt, idx.mentionId
            """ + (limit.map { " LIMIT \($0)" } ?? "")
        return try store.database.dbWriter.read { db in
            try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments)).compactMap(ReminderEntry.init(row:))
        }
    }

    /// Все строки индекса, сделанные тоже.
    public func allEntries() throws -> [ReminderEntry] {
        try store.database.dbWriter.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM reminder_index ORDER BY fireAt, mentionId").compactMap(ReminderEntry.init(row:))
        }
    }

    /// Сделанные напоминания (для красной просроченной даты в тексте — только несделанные).
    public func doneMentionIds() throws -> Set<UUID> {
        try store.database.dbWriter.read { db in
            Set(try String.fetchAll(db, sql: "SELECT mentionId FROM reminder_state WHERE doneAt IS NOT NULL").compactMap(UUID.init(uuidString:)))
        }
    }

    /// Отметить показ на этом Mac (локально, не синхронизируется).
    public func setDelivered(_ mentionIds: [UUID], at moment: Date?) throws {
        guard !mentionIds.isEmpty else { return }
        let marks = Array(repeating: "?", count: mentionIds.count).joined(separator: ", ")
        try store.database.dbWriter.write { db in
            try db.execute(sql: "UPDATE reminder_index SET deliveredAt = ? WHERE mentionId IN (\(marks))",
                           arguments: StatementArguments([moment.map(Self.storedMoment)] + mentionIds.map(\.indexText)))
        }
    }

    /// Будущие напоминания, отданные системе, но больше не стоящие в очереди: они не показаны.
    func clearHandedOver(after moment: Date, except kept: Set<UUID>) throws {
        let marks = kept.isEmpty ? "" : " AND mentionId NOT IN (\(Array(repeating: "?", count: kept.count).joined(separator: ", ")))"
        try store.database.dbWriter.write { db in
            try db.execute(sql: "UPDATE reminder_index SET deliveredAt = NULL WHERE deliveredAt IS NOT NULL AND fireAt > ?" + marks,
                           arguments: StatementArguments([Self.storedMoment(moment)] + kept.map(\.indexText)))
        }
    }

    /// Заголовок и текст уведомления: название страницы и текст блока до 100 знаков (contracts/blocks-and-keys.md).
    public func content(of entry: ReminderEntry, calendar: Calendar = .current) throws -> (title: String, body: String) {
        try store.database.dbWriter.read { db in
            let titles = try Dictionary(Row.fetchAll(db, sql: "SELECT id, title FROM page").compactMap { row -> (UUID, String)? in
                guard let id = UUID(uuidString: row["id"]) else { return nil }
                return (id, row["title"])
            }) { first, _ in first }
            let title = titles[entry.pageId].map { $0.isEmpty ? Page.untitledTitle : $0 } ?? Page.untitledTitle
            guard let row = try Row.fetchOne(db, sql: "SELECT text, textStyles FROM block WHERE id = ?", arguments: [entry.blockId.indexText]),
                  let runs = try? JSONDecoder().decode([StyledRun].self, from: Data((row["textStyles"] as String).utf8)) else {
                return (title, "")
            }
            let text = InlineText(row["text"], runs: runs).plainText(pageTitle: { titles[$0] }, calendar: calendar)
            let flat = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            return (title, flat.count > Self.bodyLength ? String(flat.prefix(Self.bodyLength - 1)) + "…" : flat)
        }
    }

    static let bodyLength = 100
}

extension ReminderEntry {
    init?(row: Row) {
        guard let mentionId = UUID(uuidString: row["mentionId"]), let pageId = UUID(uuidString: row["pageId"]),
              let blockId = UUID(uuidString: row["blockId"]), let fireAt = row["fireAt"] as Date? else { return nil }
        self.init(mentionId: mentionId, pageId: pageId, blockId: blockId, fireAt: fireAt, deliveredAt: row["deliveredAt"])
    }
}
