import Foundation
import GRDB

/// Разделы «Избранное» и «Недавние» (research R4): запросы по индексам `page_by_favorite` и `page_by_visit`,
/// без текста блоков. Страница в корзине — сама или под страницей в корзине — в разделы не попадает.
extension NotesStore {
    /// Избранное по ключу порядка; шаблоны остаются.
    public func favoritePages() throws -> [Page] {
        try database.dbWriter.read { db in
            let hidden = try Self.trashedPageIds(db)
            return try Row.fetchAll(db, sql: Self.favoritesQuery).map(Page.init(row:)).filter { !hidden.contains($0.id) }
        }
    }

    /// Недавние: свежая сверху, без шаблонов и их подстраниц; `limit` — 5 в панели, 50 в списке «Показать все».
    public func recentPages(limit: Int) throws -> [Page] {
        try database.dbWriter.read { db in
            let hidden = try Self.trashedPageIds(db).union(Self.templatePageIds(db))
            var result: [Page] = []
            // По индексу с запасом на скрытые; скрытых много — следующая порция.
            var fetched = 0
            while result.count < limit {
                let rows = try Row.fetchAll(db, sql: Self.recentsQuery + " OFFSET ?", arguments: [limit * 2, fetched])
                guard !rows.isEmpty else { break }
                fetched += rows.count
                result += try rows.map(Page.init(row:)).filter { !hidden.contains($0.id) }
            }
            return Array(result.prefix(limit))
        }
    }

    static let favoritesQuery = "SELECT * FROM page INDEXED BY page_by_favorite WHERE favorite IS NOT NULL ORDER BY favorite"
    static let recentsQuery = """
        SELECT * FROM page INDEXED BY page_by_visit WHERE visitedAt IS NOT NULL AND isTemplate = 0 ORDER BY visitedAt DESC LIMIT ?
        """

    /// Страницы в корзине вместе с подстраницами (корзина помечает только корень ветки).
    static func trashedPageIds(_ db: Database) throws -> Set<UUID> {
        try branchIds(db, rootsWhere: "trashedAt IS NOT NULL")
    }

    private static func templatePageIds(_ db: Database) throws -> Set<UUID> {
        try branchIds(db, rootsWhere: "isTemplate = 1")
    }

    private static func branchIds(_ db: Database, rootsWhere condition: String) throws -> Set<UUID> {
        Set(try String.fetchAll(db, sql: """
            WITH RECURSIVE branch(id) AS (
                SELECT id FROM page WHERE \(condition)
                UNION SELECT page.id FROM page JOIN branch ON page.parentId = branch.id
            )
            SELECT id FROM branch
            """).compactMap(UUID.init(uuidString:)))
    }
}
