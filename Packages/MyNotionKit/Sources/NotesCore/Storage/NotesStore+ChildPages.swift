import Foundation
import GRDB

extension NotesStore {
    /// Страницы-дети и их блоки — одним чтением, по id (строки базы для выгрузки: тысячи страниц без тысячи чтений).
    public func childPageContents(of parentId: UUID) throws -> [UUID: PageContent] {
        try database.dbWriter.read { db in
            let parent = parentId.databaseText
            let pages = try Row.fetchAll(db, sql: "SELECT * FROM page WHERE parentId = ?", arguments: [parent]).map(Page.init(row:))
            var blocks: [UUID: [Block]] = [:]
            let rows = try Row.fetchCursor(db, sql: """
                SELECT b.* FROM block b JOIN page p ON p.id = b.pageId WHERE p.parentId = ? AND b.isDeleted = 0
                ORDER BY b.pageId, b.sortKey, b.id
                """, arguments: [parent])
            var columns: BlockColumns?
            while let row = try rows.next() {
                let known = try columns ?? BlockColumns(row)
                columns = known
                let block = try Block(row: row, columns: known)
                blocks[block.pageId, default: []].append(block)
            }
            let kinds = BlockKind.allCases.filter(\.isContainer).map { "'\($0.rawValue)'" }.joined(separator: ", ")
            var removed: [UUID: [UUID: UUID?]] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT b.pageId, b.id, b.containerId FROM block b JOIN page p ON p.id = b.pageId
                WHERE p.parentId = ? AND b.isDeleted = 1 AND b.kind IN (\(kinds))
                """, arguments: [parent]) {
                guard let pageId = RowDecoding.optionalUUID(row, "pageId"), let id = RowDecoding.optionalUUID(row, "id") else { continue }
                removed[pageId, default: [:]][id] = .some(RowDecoding.optionalUUID(row, "containerId"))
            }
            return Dictionary(uniqueKeysWithValues: pages.map {
                ($0.id, PageContent(page: $0, blocks: blocks[$0.id] ?? [], removedContainers: removed[$0.id] ?? [:]))
            })
        }
    }

    /// Страница и все страницы под ней (с корзиной), без блоков — ветка для выгрузки одной базы.
    public func branchOutline(_ rootId: UUID) throws -> [Page] {
        try database.dbWriter.read { db in
            try Row.fetchAll(db, sql: """
                WITH RECURSIVE branch(id) AS (SELECT ? UNION ALL SELECT page.id FROM page JOIN branch ON page.parentId = branch.id)
                SELECT page.* FROM page JOIN branch ON branch.id = page.id ORDER BY page.sortKey, page.id
                """, arguments: [rootId.databaseText]).map(Page.init(row:))
        }
    }
}
