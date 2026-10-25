import Foundation
import GRDB
import NotesCore
import Sync

/// Ссылка, как её помнит этот Mac (таблица `page_share`, миграция v11).
public struct PageShare: Sendable, Hashable {
    public let pageId: UUID
    public let token: String
    public let enabled: Bool
    public let includeSubpages: Bool
    /// Digest снимка, который лежит на сервере целиком, с файлами; `nil` — снимок нужно положить.
    public let publishedDigest: String?

    public func url(on server: URL) -> URL {
        server.appendingPathComponent("s").appendingPathComponent(token)
    }
}

/// Копия состояния ссылок с сервера: окно «Поделиться» открывается сразу, правки знают, что публиковать.
public struct PageShareStore: Sendable {
    private let database: AppDatabase
    private let now: @Sendable () -> Date

    public init(database: AppDatabase, now: @escaping @Sendable () -> Date = { Date() }) {
        self.database = database
        self.now = now
    }

    public func share(_ pageId: UUID) throws -> PageShare? {
        try database.dbWriter.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM page_share WHERE pageId = ?", arguments: [pageId.databaseText]).flatMap(Self.share)
        }
    }

    public func all() throws -> [PageShare] {
        try database.dbWriter.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM page_share ORDER BY pageId").compactMap(Self.share)
        }
    }

    /// Запомнить состояние с сервера. Снимок, который сервер помнит другим, считается неопубликованным.
    public func save(_ remote: SyncShare) throws {
        try database.dbWriter.write { db in try save(remote, in: db) }
    }

    /// Весь список с сервера: ссылки, которых там нет, забываются.
    public func replaceAll(with remote: [SyncShare]) throws {
        try database.dbWriter.write { db in
            let keep = Set(remote.map(\.pageId.databaseText))
            for id in try String.fetchAll(db, sql: "SELECT pageId FROM page_share") where !keep.contains(id) {
                try db.execute(sql: "DELETE FROM page_share WHERE pageId = ?", arguments: [id])
            }
            for share in remote { try save(share, in: db) }
        }
    }

    public func setPublishedDigest(_ digest: String?, of pageId: UUID) throws {
        try database.dbWriter.write { db in
            try db.execute(sql: "UPDATE page_share SET publishedDigest = ? WHERE pageId = ?", arguments: [digest, pageId.databaseText])
        }
    }

    public func remove(_ pageId: UUID) throws {
        try database.dbWriter.write { db in
            try db.execute(sql: "DELETE FROM page_share WHERE pageId = ?", arguments: [pageId.databaseText])
        }
    }

    private func save(_ remote: SyncShare, in db: Database) throws {
        let id = remote.pageId.databaseText
        let local = try String.fetchOne(db, sql: "SELECT publishedDigest FROM page_share WHERE pageId = ?", arguments: [id])
        let digest = remote.enabled && remote.digest != nil && remote.digest == local ? local : nil
        try db.execute(sql: """
            INSERT INTO page_share (pageId, token, enabled, includeSubpages, publishedDigest, updatedAt) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(pageId) DO UPDATE SET token = excluded.token, enabled = excluded.enabled,
                includeSubpages = excluded.includeSubpages, publishedDigest = excluded.publishedDigest, updatedAt = excluded.updatedAt
            """, arguments: [id, remote.token, remote.enabled, remote.includeSubpages, digest, now()])
    }

    private static func share(_ row: Row) -> PageShare? {
        guard let pageId = UUID(uuidString: row["pageId"]) else { return nil }
        return PageShare(pageId: pageId, token: row["token"], enabled: row["enabled"], includeSubpages: row["includeSubpages"],
                         publishedDigest: row["publishedDigest"])
    }
}
