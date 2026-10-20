import Foundation
import GRDB
import NotesCore

/// Первое заполнение `page_link` по всем блокам (data-model.md, «page_link»): один раз после первого запуска v7,
/// в фоне, после готовности редактора. Пачками по `batchSize` блоков, каждая — своей короткой записью, чтобы набор
/// на главном потоке не ждал; между пачками отдаёт поток. Отметка «построен» ставится вместе с последней пачкой.
/// Блок читается внутри записи пачки, поэтому правка, пришедшая между пачками, не затирается устаревшим.
public struct BacklinkIndexBuild: Sendable {
    /// Ключ отметки в `app_meta`.
    public static let builtKey = "backlinkIndexBuilt"

    private let store: NotesStore
    private let batchSize: Int

    public init(store: NotesStore, batchSize: Int = 2_000) {
        self.store = store
        self.batchSize = max(batchSize, 1)
    }

    /// `true` — построено сейчас; `false` — уже было построено.
    @discardableResult
    public func runIfNeeded() async throws -> Bool {
        if try store.appMeta(Self.builtKey) != nil { return false }
        var position: Int64 = 0
        while true {
            if Task.isCancelled { throw CancellationError() }
            guard let next = try fillBatch(after: position) else { break }
            position = next
            await Task.yield()
        }
        return true
    }

    /// Одна пачка; `nil` — блоки кончились (отметка поставлена).
    private func fillBatch(after position: Int64) throws -> Int64? {
        try store.database.dbWriter.write { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT rowid, id, pageId, kind, linkedPageId, textStyles FROM block
                WHERE rowid > ? AND isDeleted = 0 AND (kind = 'pageLink' OR textStyles LIKE '%"mention"%')
                ORDER BY rowid LIMIT ?
                """, arguments: [position, batchSize])
            for row in rows {
                let blockId: String = row["id"]
                let pageId: String = row["pageId"]
                for target in try Self.targets(of: row) where !(try Self.isParentLinkToChild(row, target: target, in: db)) {
                    try db.execute(sql: "INSERT OR IGNORE INTO page_link (sourceBlockId, sourcePageId, targetPageId) VALUES (?, ?, ?)",
                                   arguments: [blockId, pageId, target])
                }
            }
            guard let last = rows.last else {
                try db.execute(sql: "INSERT INTO app_meta (key, value) VALUES (?, '1') ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                               arguments: [Self.builtKey])
                return nil
            }
            return last["rowid"] as Int64
        }
    }

    private struct Run: Decodable {
        let style: String
        let pageId: UUID?
    }

    private static func targets(of row: Row) throws -> Set<String> {
        var targets: Set<String> = []
        let styles: String = row["textStyles"]
        if styles != "[]" {
            for run in try JSONDecoder().decode([Run].self, from: Data(styles.utf8)) where run.style == "mention" {
                if let pageId = run.pageId { targets.insert(pageId.linkIndexText) }
            }
        }
        if (row["kind"] as String) == "pageLink", let linked: String = row["linkedPageId"] { targets.insert(linked) }
        return targets
    }

    private static func isParentLinkToChild(_ row: Row, target: String, in db: Database) throws -> Bool {
        guard (row["kind"] as String) == "pageLink", (row["linkedPageId"] as String?) == target else { return false }
        let parent = try String.fetchOne(db, sql: "SELECT parentId FROM page WHERE id = ?", arguments: [target])
        return parent == (row["pageId"] as String)
    }
}
