import Foundation
import GRDB
import NotesCore

/// Подключение этого Mac к серверу (data-model.md, «SyncAccount»). Токен и ключ шифрования — в связке ключей.
public struct SyncAccount: Sendable, Hashable {
    public var serverURL: URL
    /// id устройства на сервере.
    public var deviceId: String
    public var deviceName: String
    /// Пачки до этого номера включительно применены.
    public var lastPulledSeq: Int
    /// Номер последней своей отправленной пачки.
    public var lastSentSeq: Int
    /// Номер последнего снимка, который этот Mac выкладывал или скачивал.
    public var lastSnapshotSeq: Int

    public init(serverURL: URL, deviceId: String, deviceName: String, lastPulledSeq: Int = 0, lastSentSeq: Int = 0,
                lastSnapshotSeq: Int = 0) {
        self.serverURL = serverURL
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.lastPulledSeq = lastPulledSeq
        self.lastSentSeq = lastSentSeq
        self.lastSnapshotSeq = lastSnapshotSeq
    }

    /// Сервер Юрия (research R7).
    public static let defaultServerURL = URL(string: "https://mynotion.kurilov.cloud")!
}

/// Чтение и запись подключения в таблице `sync_account` (одна строка).
public struct SyncAccountStore: Sendable {
    public let store: NotesStore

    public init(store: NotesStore) {
        self.store = store
    }

    public func account() throws -> SyncAccount? {
        try store.database.dbWriter.read { try Self.account(in: $0) }
    }

    static func account(in db: Database) throws -> SyncAccount? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM sync_account WHERE id = 1"),
              let url = URL(string: row["serverURL"]) else { return nil }
        return SyncAccount(serverURL: url, deviceId: row["deviceId"], deviceName: row["deviceName"],
                           lastPulledSeq: row["lastPulledSeq"], lastSentSeq: row["lastSentSeq"],
                           lastSnapshotSeq: row["lastSnapshotSeq"])
    }

    static func isEnabled(in db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM sync_account WHERE id = 1)") ?? false
    }

    static func save(_ account: SyncAccount, in db: Database) throws {
        try db.execute(sql: """
            INSERT INTO sync_account (id, serverURL, deviceId, deviceName, lastPulledSeq, lastSentSeq, lastSnapshotSeq)
            VALUES (1, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET serverURL = excluded.serverURL, deviceId = excluded.deviceId,
                deviceName = excluded.deviceName, lastPulledSeq = excluded.lastPulledSeq,
                lastSentSeq = excluded.lastSentSeq, lastSnapshotSeq = excluded.lastSnapshotSeq
            """, arguments: [account.serverURL.absoluteString, account.deviceId, account.deviceName,
                             account.lastPulledSeq, account.lastSentSeq, account.lastSnapshotSeq])
    }

    /// Применено всё до `seq` — в той же транзакции, что и само применение.
    static func recordPulled(seq: Int, in db: Database) throws {
        try db.execute(sql: "UPDATE sync_account SET lastPulledSeq = MAX(lastPulledSeq, ?) WHERE id = 1", arguments: [seq])
    }

    public func recordSent(seq: Int) throws {
        try store.database.dbWriter.write { db in
            try db.execute(sql: "UPDATE sync_account SET lastSentSeq = MAX(lastSentSeq, ?) WHERE id = 1", arguments: [seq])
        }
    }

    public func recordPulled(seq: Int) throws {
        try store.database.dbWriter.write { try Self.recordPulled(seq: seq, in: $0) }
    }

    public func recordSnapshot(seq: Int) throws {
        try store.database.dbWriter.write { db in
            try db.execute(sql: "UPDATE sync_account SET lastSnapshotSeq = MAX(lastSnapshotSeq, ?) WHERE id = 1", arguments: [seq])
        }
    }
}
