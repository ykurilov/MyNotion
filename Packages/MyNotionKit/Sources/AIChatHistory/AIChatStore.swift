import Foundation
import GRDB
import NotesCore

/// Чат ИИ-агента в списке прошлых чатов.
public struct AIChat: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    /// Время последнего сообщения: по нему список — свежие сверху.
    public var updatedAt: Date

    init(row: Row) throws {
        id = try AIChatRows.uuid(row, "id")
        title = row["title"]
        createdAt = row["createdAt"]
        updatedAt = row["updatedAt"]
    }
}

/// Сообщение чата: тело — JSON записи чата (`ChatEntry` модуля AIAgent); хранилище его не разбирает.
public struct AIChatMessage: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var chatId: UUID
    public var position: Int
    public var createdAt: Date
    public var body: String

    init(row: Row) throws {
        id = try AIChatRows.uuid(row, "id")
        chatId = try AIChatRows.uuid(row, "chatId")
        position = row["position"]
        createdAt = row["createdAt"]
        body = row["body"]
    }
}

public enum AIChatStoreError: Error, Equatable {
    case chatNotFound
}

/// Чаты ИИ-агента в базе заметок (008): так они попадают в синхронизацию и на другие устройства.
/// Каждая правка отмечает чат к отправке (`AIChatSync`) и будит подписчиков `didChange`.
public final class AIChatStore: Sendable {
    /// Чаты изменились — здесь или пришли с другого устройства.
    public static let didChange = Notification.Name("AIChatStore.didChange")

    public let store: NotesStore

    public init(store: NotesStore) {
        self.store = store
    }

    /// Чаты без удалённых, свежие сверху.
    public func chats() throws -> [AIChat] {
        try store.database.dbWriter.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM ai_chat WHERE deletedAt IS NULL ORDER BY updatedAt DESC, id DESC").map(AIChat.init(row:))
        }
    }

    public func chat(_ id: UUID) throws -> AIChat? {
        try store.database.dbWriter.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM ai_chat WHERE id = ? AND deletedAt IS NULL", arguments: [id.databaseText]).map(AIChat.init(row:))
        }
    }

    public func messages(in chatId: UUID) throws -> [AIChatMessage] {
        try store.database.dbWriter.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM ai_chat_message WHERE chatId = ? \(AIChatRows.messageOrder)",
                             arguments: [chatId.databaseText]).map(AIChatMessage.init(row:))
        }
    }

    @discardableResult
    public func createChat(id: UUID = UUID(), title: String, at date: Date = Date()) throws -> AIChat {
        try store.write { transaction in
            try transaction.database.execute(sql: """
                INSERT INTO ai_chat (id, title, createdAt, updatedAt, clock, sendMark) VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [id.databaseText, title, date, date, transaction.clock.now().description, AIChatSync.newSendMark()])
        }
        notify()
        return try chat(id) ?? { throw AIChatStoreError.chatNotFound }()
    }

    public func rename(_ chatId: UUID, to title: String) throws {
        try store.write { transaction in
            try transaction.database.execute(sql: "UPDATE ai_chat SET title = ?, clock = ?, sendMark = ? WHERE id = ?",
                                             arguments: [title, transaction.clock.now().description, AIChatSync.newSendMark(), chatId.databaseText])
            guard transaction.database.changesCount > 0 else { throw AIChatStoreError.chatNotFound }
        }
        notify()
    }

    /// Дописать сообщение в конец чата; то же `id` второй раз ничего не меняет.
    public func append(_ body: String, id: UUID, to chatId: UUID, at date: Date = Date()) throws {
        try store.write { transaction in
            let db = transaction.database
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM ai_chat WHERE id = ?)", arguments: [chatId.databaseText]) == true else {
                throw AIChatStoreError.chatNotFound
            }
            try db.execute(sql: """
                INSERT OR IGNORE INTO ai_chat_message (id, chatId, position, createdAt, body, syncPending)
                VALUES (?, ?, (SELECT COALESCE(MAX(position) + 1, 0) FROM ai_chat_message WHERE chatId = ?), ?, ?, 1)
                """, arguments: [id.databaseText, chatId.databaseText, chatId.databaseText, date, body])
            guard db.changesCount > 0 else { return }
            try db.execute(sql: "UPDATE ai_chat SET updatedAt = MAX(updatedAt, ?) WHERE id = ?", arguments: [date, chatId.databaseText])
        }
        notify()
    }

    private func notify() {
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}

enum AIChatRows {
    /// Один порядок на всех устройствах: два устройства могли дописать сообщения с одним номером.
    static let messageOrder = "ORDER BY position, createdAt, id"

    static func uuid(_ row: Row, _ column: String) throws -> UUID {
        guard let id = (row[column] as String?).flatMap(UUID.init(uuidString:)) else { throw AIChatStoreError.chatNotFound }
        return id
    }
}
