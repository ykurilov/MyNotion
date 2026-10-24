import Foundation
import GRDB
import NotesCore

/// Версия в списке истории — без снимка (data-model.md, «page_version»).
public struct PageVersionInfo: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let pageId: UUID
    public let createdAt: Date
    /// Mac-автор последней правки, вошедшей в снимок.
    public let deviceName: String
    public let summary: VersionSummary
    /// Размер сжатого снимка.
    public let byteCount: Int
}

/// Страница, ждущая снимка (`page_version_due`).
public struct VersionDueMark: Sendable, Hashable {
    public let pageId: UUID
    public let lastChangeAt: Date
    public let deviceName: String
}

/// Версии страниц на этом Mac: таблицы `page_version`, `page_version_file` и `page_version_due`. Пишет мимо транзакций
/// записей и подписчиков: версии не синхронизируются и не меняют страниц (research R11). Файлы версии (`page_version_file`)
/// сборщик сирот не стирает, пока версия хранится.
public final class PageVersionStore: Sendable {
    public let store: NotesStore

    public init(store: NotesStore) {
        self.store = store
    }

    private var database: DatabasePool { store.database.dbWriter }

    // MARK: Версии

    /// Версии страницы, новые первыми.
    public func versions(ofPage pageId: UUID) throws -> [PageVersionInfo] {
        try database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, pageId, createdAt, deviceName, summary, byteCount FROM page_version
                WHERE pageId = ? ORDER BY createdAt DESC, id DESC
                """, arguments: [pageId.versionKey]).map(Self.info)
        }
    }

    /// Снимок версии; `nil` — версии нет (стёрта прореживанием).
    public func snapshot(_ versionId: UUID) throws -> PageSnapshot? {
        guard let data = try database.read({ db in
            try Data.fetchOne(db, sql: "SELECT snapshot FROM page_version WHERE id = ?", arguments: [versionId.versionKey])
        }) else { return nil }
        return try PageSnapshot(compressed: data)
    }

    /// Последняя версия страницы со снимком.
    public func latest(ofPage pageId: UUID) throws -> (info: PageVersionInfo, snapshot: PageSnapshot)? {
        guard let row = try database.read({ db in
            try Row.fetchOne(db, sql: "SELECT * FROM page_version WHERE pageId = ? ORDER BY createdAt DESC, id DESC LIMIT 1",
                             arguments: [pageId.versionKey])
        }) else { return nil }
        return (try Self.info(row), try PageSnapshot(compressed: row["snapshot"]))
    }

    /// Записать версию; отметка страницы снимается, если после `createdAt` правок не было.
    @discardableResult
    public func save(_ snapshot: PageSnapshot, pageId: UUID, createdAt: Date, deviceName: String,
                     summary: VersionSummary) throws -> PageVersionInfo {
        let data = try snapshot.compressed()
        let info = PageVersionInfo(id: .timeOrdered(), pageId: pageId, createdAt: createdAt, deviceName: deviceName, summary: summary,
                                   byteCount: data.count)
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO page_version (id, pageId, createdAt, deviceName, snapshot, summary, byteCount) VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [info.id.versionKey, pageId.versionKey, createdAt, deviceName, data,
                                 String(decoding: try JSONEncoder().encode(summary), as: UTF8.self), data.count])
            for fileId in snapshot.fileIds {
                try db.execute(sql: "INSERT OR IGNORE INTO page_version_file (versionId, fileId) VALUES (?, ?)",
                               arguments: [info.id.versionKey, fileId.versionKey])
            }
            try db.execute(sql: "DELETE FROM page_version_due WHERE pageId = ? AND lastChangeAt <= ?", arguments: [pageId.versionKey, createdAt])
        }
        return info
    }

    /// Стереть версии (прореживание).
    public func delete(_ versionIds: Set<UUID>) throws {
        guard !versionIds.isEmpty else { return }
        try database.write { db in
            for id in versionIds {
                try db.execute(sql: "DELETE FROM page_version WHERE id = ?", arguments: [id.versionKey])
                try db.execute(sql: "DELETE FROM page_version_file WHERE versionId = ?", arguments: [id.versionKey])
            }
        }
    }

    /// Версия — вид страницы перед восстановлением другой версии: прореживание держит её отдельно от остальных.
    public func markBeforeRestore(_ versionId: UUID) throws {
        try database.write { db in
            try db.execute(sql: "UPDATE page_version SET isBeforeRestore = 1 WHERE id = ?", arguments: [versionId.versionKey])
        }
    }

    /// Время версий каждой страницы (для прореживания).
    public func allVersionStamps() throws -> [UUID: [VersionStamp]] {
        try database.read { db in
            var result: [UUID: [VersionStamp]] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT id, pageId, createdAt, isBeforeRestore, json_extract(summary, '$.agent') IS NOT NULL AS isAgentCheckpoint FROM page_version
                """) {
                guard let id = UUID(uuidString: row["id"]), let pageId = UUID(uuidString: row["pageId"]) else { continue }
                result[pageId, default: []].append(VersionStamp(id: id, createdAt: row["createdAt"], isBeforeRestore: row["isBeforeRestore"],
                                                                 isAgentCheckpoint: row["isAgentCheckpoint"]))
            }
            return result
        }
    }

    /// Место версий страницы на диске, байт.
    public func byteCount(ofPage pageId: UUID) throws -> Int {
        try database.read { db in
            try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(byteCount), 0) FROM page_version WHERE pageId = ?", arguments: [pageId.versionKey]) ?? 0
        }
    }

    // MARK: Отметки «пора снимок»

    public func duePages() throws -> [VersionDueMark] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM page_version_due ORDER BY lastChangeAt").compactMap { row in
                guard let pageId = UUID(uuidString: row["pageId"]) else { return nil }
                return VersionDueMark(pageId: pageId, lastChangeAt: row["lastChangeAt"], deviceName: row["deviceName"])
            }
        }
    }

    public func dueMark(ofPage pageId: UUID) throws -> VersionDueMark? {
        try database.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM page_version_due WHERE pageId = ?", arguments: [pageId.versionKey]).map { row in
                VersionDueMark(pageId: pageId, lastChangeAt: row["lastChangeAt"], deviceName: row["deviceName"])
            }
        }
    }

    /// Снять отметку, если после `upTo` правок не было.
    public func clearDue(pageId: UUID, upTo date: Date) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM page_version_due WHERE pageId = ? AND lastChangeAt <= ?", arguments: [pageId.versionKey, date])
        }
    }

    // MARK: В транзакции записи (подписчик)

    static func markDue(_ pageIds: Set<UUID>, at date: Date, deviceName: String, in db: Database) throws {
        for pageId in pageIds {
            try db.execute(sql: """
                INSERT INTO page_version_due (pageId, lastChangeAt, deviceName) VALUES (?, ?, ?)
                ON CONFLICT(pageId) DO UPDATE SET lastChangeAt = excluded.lastChangeAt, deviceName = excluded.deviceName
                """, arguments: [pageId.versionKey, date, deviceName])
        }
    }

    static func erase(pages pageIds: [UUID], in db: Database) throws {
        for pageId in pageIds {
            try db.execute(sql: """
                DELETE FROM page_version_file WHERE versionId IN (SELECT id FROM page_version WHERE pageId = ?)
                """, arguments: [pageId.versionKey])
            try db.execute(sql: "DELETE FROM page_version WHERE pageId = ?", arguments: [pageId.versionKey])
            try db.execute(sql: "DELETE FROM page_version_due WHERE pageId = ?", arguments: [pageId.versionKey])
        }
    }

    private static func info(_ row: Row) throws -> PageVersionInfo {
        guard let id = UUID(uuidString: row["id"]), let pageId = UUID(uuidString: row["pageId"]) else {
            throw NotesStoreError.corruptedRecord("версия страницы без id")
        }
        let summary = (try? JSONDecoder().decode(VersionSummary.self, from: Data((row["summary"] as String).utf8))) ?? VersionSummary()
        return PageVersionInfo(id: id, pageId: pageId, createdAt: row["createdAt"], deviceName: row["deviceName"], summary: summary,
                               byteCount: row["byteCount"])
    }
}

/// id, время версии и пометки «до восстановления» и «до правки агента» — всё, что нужно прореживанию.
public struct VersionStamp: Sendable, Hashable {
    public let id: UUID
    public let createdAt: Date
    public let isBeforeRestore: Bool
    public let isAgentCheckpoint: Bool

    public init(id: UUID, createdAt: Date, isBeforeRestore: Bool = false, isAgentCheckpoint: Bool = false) {
        self.id = id
        self.createdAt = createdAt
        self.isBeforeRestore = isBeforeRestore
        self.isAgentCheckpoint = isAgentCheckpoint
    }
}

extension UUID {
    /// Как id в таблицах ядра: строчными буквами.
    var versionKey: String { uuidString.lowercased() }
}
