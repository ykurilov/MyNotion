import Foundation
import GRDB

/// Разделы «Избранное» и «Недавние» (research R4): запросы по индексам `page_by_favorite` и `page_by_visit`,
/// без текста блоков. Страница в корзине — сама или под страницей в корзине — в разделы не попадает.
extension NotesStore {
    /// Избранное по ключу порядка; шаблоны остаются.
    public func favoritePages() throws -> [Page] {
        try database.dbWriter.read { db in
            let pages = try Row.fetchAll(db, sql: Self.favoritesQuery).map(Page.init(row:))
            let hidden = try Self.hiddenPageIds(among: pages, hidingTemplates: false, db)
            return pages.filter { !hidden.contains($0.id) }
        }
    }

    /// Недавние: свежая сверху, без шаблонов и их подстраниц; `limit` — 5 в панели, 50 в списке «Показать все».
    public func recentPages(limit: Int) throws -> [Page] {
        try database.dbWriter.read { db in
            var result: [Page] = []
            // По индексу с запасом на скрытые; скрытых много — следующая порция.
            var fetched = 0
            while result.count < limit {
                let rows = try Row.fetchAll(db, sql: Self.recentsQuery + " OFFSET ?", arguments: [limit * 2, fetched])
                guard !rows.isEmpty else { break }
                fetched += rows.count
                let pages = try rows.map(Page.init(row:))
                let hidden = try Self.hiddenPageIds(among: pages, hidingTemplates: true, db)
                result += pages.filter { !hidden.contains($0.id) }
            }
            return Array(result.prefix(limit))
        }
    }

    static let favoritesQuery = "SELECT * FROM page INDEXED BY page_by_favorite WHERE favorite IS NOT NULL ORDER BY favorite"
    static let recentsQuery = """
        SELECT * FROM page INDEXED BY page_by_visit WHERE visitedAt IS NOT NULL AND isTemplate = 0 ORDER BY visitedAt DESC LIMIT ?
        """

    /// Кандидаты, которые сами или через предка в корзине (корзина помечает только корень ветки) либо — с
    /// `hidingTemplates` — в шаблоне. Проход вверх по предкам кандидатов по первичному ключу: искать все ветки корзины
    /// и шаблонов — полный проход по `page` вместе со строками баз (на холодном диске — секунда к запуску, T030).
    static func hiddenAmongQuery(hidingTemplates: Bool) -> String {
        """
        WITH RECURSIVE ancestry(candidate, id) AS (
            SELECT value, value FROM json_each(?)
            UNION SELECT ancestry.candidate, page.parentId FROM ancestry JOIN page ON page.id = ancestry.id
                WHERE page.parentId IS NOT NULL)
        SELECT DISTINCT ancestry.candidate FROM ancestry JOIN page ON page.id = ancestry.id
        WHERE page.trashedAt IS NOT NULL\(hidingTemplates ? " OR page.isTemplate = 1" : "")
        """
    }

    static func hiddenPageIds(among pages: [Page], hidingTemplates: Bool, _ db: Database) throws -> Set<UUID> {
        guard !pages.isEmpty else { return [] }
        let ids = "[" + pages.map { "\"\($0.id.databaseText)\"" }.joined(separator: ",") + "]"
        return Set(try String.fetchAll(db, sql: hiddenAmongQuery(hidingTemplates: hidingTemplates), arguments: [ids])
            .compactMap(UUID.init(uuidString:)))
    }
}
