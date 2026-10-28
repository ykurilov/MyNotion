import Foundation
import GRDB
import NotesCore

/// Чат в пачке или снимке синхронизации: заголовок с меткой часов и сообщения. В пачке — только неотправленные
/// сообщения, в снимке — все. Поля необязательные там, где формат может расти: старый MyNotion пропускает весь список.
public struct AIChatSyncRecord: Sendable, Hashable, Codable {
    public struct Message: Sendable, Hashable, Codable {
        public var id: UUID
        public var position: Int
        public var createdAt: Date
        public var body: String

        public init(id: UUID, position: Int, createdAt: Date, body: String) {
            self.id = id
            self.position = position
            self.createdAt = createdAt
            self.body = body
        }
    }

    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    /// Метка последней правки названия или удаления: побеждает поздняя.
    public var clock: HybridTimestamp
    public var messages: [Message]

    public init(id: UUID, title: String, createdAt: Date, updatedAt: Date, deletedAt: Date?, clock: HybridTimestamp, messages: [Message]) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.clock = clock
        self.messages = messages
    }
}

/// Отправка и слияние чатов. Сообщения не меняются после записи: сходятся объединением по id. Название и удаление —
/// по поздней метке, время последнего сообщения — наибольшее. Устройство, которое могло пропустить чаты (обновилось
/// со старой версии или начало со снимка старой версии), просит другие прислать свои; ответ не просит.
package enum AIChatSync {
    private static let requestMark = "sync.aiChats.request"
    private static let introducedMark = "sync.aiChats.introduced"
    /// Порция одной пачки: сервер принимает пачки до 4 МБ, а тело сообщения в JSON ещё растёт от экранирования.
    package static let defaultMaxBytes = 1_000_000

    package struct Pending: Sendable {
        package let records: [AIChatSyncRecord]
        package let request: String?
        /// Отметки заголовков на момент чтения: правка во время отправки ставит новую, и она не снимается.
        let headerMarks: [UUID: Int64]
        let messageIds: [UUID]
    }

    static func newSendMark() -> Int64 { Int64.random(in: 1...Int64.max) }

    /// Следующая порция к отправке; `nil` — отправлять нечего. Заголовок едет с каждой порцией своих сообщений.
    package static func pending(in store: NotesStore, maxBytes: Int = defaultMaxBytes) throws -> Pending? {
        try store.database.dbWriter.read { db in
            let request = try meta(requestMark, in: db)
            let chats = try Row.fetchAll(db, sql: """
                SELECT * FROM ai_chat
                WHERE sendMark IS NOT NULL OR id IN (SELECT chatId FROM ai_chat_message WHERE syncPending = 1)
                ORDER BY updatedAt, id
                """)
            var records: [AIChatSyncRecord] = []
            var headerMarks: [UUID: Int64] = [:]
            var messageIds: [UUID] = []
            var bytes = 0
            var isFull = false
            for row in chats {
                guard !isFull, records.isEmpty || bytes < maxBytes else { break }
                var record = try header(row)
                bytes += record.title.utf8.count + 300
                if let mark = row["sendMark"] as Int64? { headerMarks[record.id] = mark }
                let rows = try Row.fetchAll(db, sql: "SELECT * FROM ai_chat_message WHERE chatId = ? AND syncPending = 1 \(AIChatRows.messageOrder)",
                                            arguments: [record.id.databaseText])
                for message in try rows.map(message) {
                    let size = message.body.utf8.count + 200
                    guard record.messages.isEmpty && records.isEmpty || bytes + size <= maxBytes else {
                        isFull = true
                        break
                    }
                    record.messages.append(message)
                    messageIds.append(message.id)
                    bytes += size
                }
                records.append(record)
            }
            guard !records.isEmpty || request != nil else { return nil }
            return Pending(records: records, request: request, headerMarks: headerMarks, messageIds: messageIds)
        }
    }

    /// Есть ли что отправить — дёшево, без тел сообщений.
    package static func hasPending(in store: NotesStore) throws -> Bool {
        try store.database.dbWriter.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT EXISTS (SELECT 1 FROM ai_chat WHERE sendMark IS NOT NULL)
                    OR EXISTS (SELECT 1 FROM ai_chat_message WHERE syncPending = 1)
                    OR EXISTS (SELECT 1 FROM app_meta WHERE key = ?)
                """, arguments: [requestMark]) ?? false
        }
    }

    /// Пачка принята сервером.
    package static func didSend(_ pending: Pending, in store: NotesStore) throws {
        try store.database.dbWriter.write { db in
            for (id, mark) in pending.headerMarks {
                try db.execute(sql: "UPDATE ai_chat SET sendMark = NULL WHERE id = ? AND sendMark = ?", arguments: [id.databaseText, mark])
            }
            for id in pending.messageIds {
                try db.execute(sql: "UPDATE ai_chat_message SET syncPending = 0 WHERE id = ?", arguments: [id.databaseText])
            }
            if let request = pending.request {
                try db.execute(sql: "DELETE FROM app_meta WHERE key = ? AND value = ?", arguments: [requestMark, request])
            }
        }
    }

    /// Чаты для снимка. Снимок уходит на сервер одним куском, а чатов за годы набирается много: в него идут самые
    /// свежие чаты целиком, пока влезают в `maxBytes`. Остальные устройство, начавшее со снимка, попросит у других пачками.
    package struct SnapshotChats: Sendable {
        package let records: [AIChatSyncRecord]
        package let isComplete: Bool
    }

    package static let snapshotMaxBytes = 8_000_000

    package static func snapshot(in db: Database, maxBytes: Int = snapshotMaxBytes) throws -> SnapshotChats {
        var sizes: [UUID: Int] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT chatId, SUM(length(CAST(body AS BLOB)) + 200) AS size FROM ai_chat_message GROUP BY chatId") {
            sizes[try AIChatRows.uuid(row, "chatId")] = row["size"]
        }
        var records: [AIChatSyncRecord] = []
        var bytes = 0
        var isComplete = true
        for row in try Row.fetchAll(db, sql: "SELECT * FROM ai_chat ORDER BY updatedAt DESC, id DESC") {
            var record = try header(row)
            let size = record.title.utf8.count + 300 + (sizes[record.id] ?? 0)
            guard bytes + size <= maxBytes else {
                isComplete = false
                continue
            }
            bytes += size
            record.messages = try Row.fetchAll(db, sql: "SELECT * FROM ai_chat_message WHERE chatId = ? \(AIChatRows.messageOrder)",
                                               arguments: [record.id.databaseText]).map(message)
            records.append(record)
        }
        return SnapshotChats(records: records.reversed(), isComplete: isComplete)
    }

    /// Чаты из снимка. Снимок старой версии (без чатов) или с частью чатов — недостающие попросить у других устройств.
    @discardableResult
    package static func mergeSnapshot(_ records: [AIChatSyncRecord]?, isComplete: Bool, in transaction: NotesTransaction) throws -> Bool {
        let changed = try merge(records, requestedByOthers: false, in: transaction)
        if records == nil {
            try markAllForSending(requestingOthers: true, in: transaction.database)
        } else if !isComplete {
            try setMeta(requestMark, UUID().uuidString, in: transaction.database)
        }
        return changed
    }

    /// Пришедшие чаты. `true` — что-то поменялось: списку чатов перечитать.
    @discardableResult
    package static func merge(_ records: [AIChatSyncRecord]?, requestedByOthers: Bool, in transaction: NotesTransaction) throws -> Bool {
        let db = transaction.database
        var changed = false
        for record in records ?? [] {
            if record.clock != .distantPast { transaction.clock.receive(record.clock) }
            let id = record.id.databaseText
            if let local = try String.fetchOne(db, sql: "SELECT clock FROM ai_chat WHERE id = ?", arguments: [id]) {
                if HybridTimestamp(local).map({ record.clock > $0 }) ?? true {
                    try db.execute(sql: "UPDATE ai_chat SET title = ?, deletedAt = ?, clock = ? WHERE id = ?",
                                   arguments: [record.title, record.deletedAt, record.clock.description, id])
                    changed = true
                }
                try db.execute(sql: "UPDATE ai_chat SET updatedAt = ? WHERE id = ? AND updatedAt < ?",
                               arguments: [record.updatedAt, id, record.updatedAt])
                changed = changed || db.changesCount > 0
            } else {
                try db.execute(sql: """
                    INSERT INTO ai_chat (id, title, createdAt, updatedAt, deletedAt, clock, sendMark) VALUES (?, ?, ?, ?, ?, ?, NULL)
                    """, arguments: [id, record.title, record.createdAt, record.updatedAt, record.deletedAt, record.clock.description])
                changed = true
            }
            for message in record.messages {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO ai_chat_message (id, chatId, position, createdAt, body, syncPending) VALUES (?, ?, ?, ?, ?, 0)
                    """, arguments: [message.id.databaseText, id, message.position, message.createdAt, message.body])
                changed = changed || db.changesCount > 0
            }
        }
        if requestedByOthers { try markAllForSending(requestingOthers: false, in: db) }
        return changed
    }

    /// Отметить к отправке все чаты; `requestingOthers` — и попросить другие устройства прислать свои.
    package static func markAllForSending(requestingOthers: Bool, in db: Database) throws {
        try db.execute(sql: "UPDATE ai_chat SET sendMark = ?", arguments: [newSendMark()])
        try db.execute(sql: "UPDATE ai_chat_message SET syncPending = 1")
        if requestingOthers { try setMeta(requestMark, UUID().uuidString, in: db) }
    }

    /// Включили синхронизацию: свои чаты уходят; чужие придут журналом или снимком.
    package static func introduce(in db: Database) throws {
        try markAllForSending(requestingOthers: false, in: db)
        try setMeta(introducedMark, "1", in: db)
    }

    /// Первый запуск версии с чатами на уже подключённом устройстве: чаты в пачках, пришедших до обновления,
    /// старая версия пропустила — попросить другие прислать.
    package static func introduceIfNeeded(in db: Database) throws {
        guard try meta(introducedMark, in: db) == nil else { return }
        try markAllForSending(requestingOthers: true, in: db)
        try setMeta(introducedMark, "1", in: db)
    }

    /// Синхронизацию выключили: просить больше некого.
    package static func forgetPending(in db: Database) throws {
        try db.execute(sql: "DELETE FROM app_meta WHERE key = ?", arguments: [requestMark])
    }

    // MARK: Внутреннее

    private static func header(_ row: Row) throws -> AIChatSyncRecord {
        AIChatSyncRecord(id: try AIChatRows.uuid(row, "id"), title: row["title"], createdAt: row["createdAt"], updatedAt: row["updatedAt"],
                         deletedAt: row["deletedAt"], clock: HybridTimestamp(row["clock"] as String) ?? .distantPast, messages: [])
    }

    private static func message(_ row: Row) throws -> AIChatSyncRecord.Message {
        AIChatSyncRecord.Message(id: try AIChatRows.uuid(row, "id"), position: row["position"], createdAt: row["createdAt"], body: row["body"])
    }

    private static func meta(_ key: String, in db: Database) throws -> String? {
        try String.fetchOne(db, sql: "SELECT value FROM app_meta WHERE key = ?", arguments: [key])
    }

    private static func setMeta(_ key: String, _ value: String, in db: Database) throws {
        try db.execute(sql: "INSERT INTO app_meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                       arguments: [key, value])
    }
}
