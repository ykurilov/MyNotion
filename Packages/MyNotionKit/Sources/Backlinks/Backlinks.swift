import Foundation
import GRDB
import NotesCore

/// Страница-источник обратной ссылки и первый по порядку блок, где стоит ссылка (для перехода к месту).
public struct BacklinkSource: Sendable, Hashable {
    public let pageId: UUID
    public let blockId: UUID

    public init(pageId: UUID, blockId: UUID) {
        self.pageId = pageId
        self.blockId = blockId
    }
}

/// Запросы к индексу обратных ссылок (research R10): счёт и список. Считаются разные страницы-источники,
/// не в корзине (ни сама, ни через предка) и не шаблоны; сама страница себя не считает.
/// Пока индекс не построен (`BacklinkIndexBuild`), ссылок «нет».
public struct Backlinks: Sendable {
    private let store: NotesStore

    public init(store: NotesStore) {
        self.store = store
    }

    /// Число обратных ссылок — один запрос по индексу `page_link_by_target`, без чтения блоков.
    public func count(of pageId: UUID) throws -> Int {
        try store.database.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM (\(Self.sourcePagesSQL))", arguments: Self.arguments(for: pageId)) ?? 0
        }
    }

    /// Список источников: сначала недавно правленные страницы.
    public func sources(of pageId: UUID) throws -> [BacklinkSource] {
        try store.database.dbWriter.read { db in
            try Row.fetchAll(db, sql: """
                SELECT live.id AS pageId, (
                    SELECT link.sourceBlockId FROM page_link link JOIN block ON block.id = link.sourceBlockId
                    WHERE link.targetPageId = :target AND link.sourcePageId = live.id
                    ORDER BY block.sortKey, block.id LIMIT 1) AS blockId
                FROM (\(Self.sourcePagesSQL)) live JOIN page ON page.id = live.id
                ORDER BY page.updatedAt DESC, page.id
                """, arguments: Self.arguments(for: pageId)).compactMap { row in
                guard let page = UUID(uuidString: row["pageId"]), let block = (row["blockId"] as String?).flatMap(UUID.init(uuidString:)) else { return nil }
                return BacklinkSource(pageId: page, blockId: block)
            }
        }
    }

    /// «1 обратная ссылка», «3 обратные ссылки», «5 обратных ссылок».
    public static func phrase(count: Int) -> String {
        let lastTwo = count % 100
        let last = count % 10
        let form = if (11...14).contains(lastTwo) { "обратных ссылок" }
        else if last == 1 { "обратная ссылка" }
        else if (2...4).contains(last) { "обратные ссылки" }
        else { "обратных ссылок" }
        return "\(count) \(form)"
    }

    /// Живые страницы-источники: у каждой — вся цепочка предков, и ни одна в ней не в корзине и не шаблон.
    private static let sourcePagesSQL = """
        WITH RECURSIVE
            sources(id) AS (
                SELECT DISTINCT sourcePageId FROM page_link
                WHERE targetPageId = :target AND sourcePageId <> :target
                    AND EXISTS (SELECT 1 FROM app_meta WHERE key = :builtKey)),
            chain(root, parentId, blocked) AS (
                SELECT page.id, page.parentId, page.trashedAt IS NOT NULL OR page.isTemplate FROM page JOIN sources ON sources.id = page.id
                UNION ALL
                SELECT chain.root, page.parentId, page.trashedAt IS NOT NULL OR page.isTemplate
                FROM page JOIN chain ON page.id = chain.parentId)
        SELECT root AS id FROM chain GROUP BY root HAVING MAX(blocked) = 0
        """

    private static func arguments(for pageId: UUID) -> StatementArguments {
        ["target": pageId.linkIndexText, "builtKey": BacklinkIndexBuild.builtKey]
    }
}
