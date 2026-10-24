import Foundation
import GRDB
import NotesCore

/// Выборки страниц без чтения всего дерева: в базе на 10 000 строк полное дерево читается ~200 мс (T052), а указателю
/// нужны только страницы с нужным названием и их предки.
enum PageQueries {
    /// Ключ названия в SQL — как `PagePath.normalized(displayTitle)`: без регистра, `ё/е`, «Без названия» у пустых.
    private static let titleKey = DatabaseFunction("mynotion_title_key", argumentCount: 1, pure: true) { values in
        let title = String.fromDatabaseValue(values[0]) ?? ""
        return PagePath.normalized(title.isEmpty ? Page.untitledTitle : title)
    }

    /// Страницы с названием `title` (по ключу) и все их предки — для сверки пути, корзины и пути в ответе.
    static func titled(_ title: String, in store: NotesStore) throws -> PageIndex {
        try withAncestors(in: store, seed: "mynotion_title_key(title) = ?", [PagePath.normalized(title)])
    }

    /// Страница и её предки.
    static func chain(of pageId: UUID, in store: NotesStore) throws -> PageIndex {
        try withAncestors(in: store, seed: "id = ?", [pageId.databaseText])
    }

    /// Дети страницы с названием `title` (по ключу) или id с префиксом `idPrefix`.
    static func children(of parentId: UUID, titled title: String?, idPrefix: String?, in store: NotesStore) throws -> [Page] {
        try store.database.dbWriter.read { db in
            db.add(function: titleKey)
            var conditions: [String] = []
            var arguments: StatementArguments = [parentId.databaseText]
            if let title {
                conditions.append("mynotion_title_key(title) = ?")
                arguments += [PagePath.normalized(title)]
            }
            if let idPrefix {
                conditions.append("lower(id) LIKE ?")
                arguments += [idPrefix.lowercased() + "%"]
            }
            let filter = conditions.isEmpty ? "" : " AND (" + conditions.joined(separator: " OR ") + ")"
            return try Row.fetchAll(db, sql: "SELECT * FROM page WHERE parentId = ?\(filter) ORDER BY sortKey, id", arguments: arguments)
                .map(Page.init(row:))
        }
    }

    static func hasChildren(_ pageId: UUID, in store: NotesStore) throws -> Bool {
        try store.database.dbWriter.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM page WHERE parentId = ?)", arguments: [pageId.databaseText]) ?? false
        }
    }

    private static func withAncestors(in store: NotesStore, seed: String, _ arguments: StatementArguments) throws -> PageIndex {
        PageIndex(try store.database.dbWriter.read { db in
            db.add(function: titleKey)
            return try Row.fetchAll(db, sql: """
                WITH RECURSIVE chain(id, parentId) AS (
                    SELECT id, parentId FROM page WHERE \(seed)
                    UNION SELECT page.id, page.parentId FROM page JOIN chain ON page.id = chain.parentId
                )
                SELECT page.* FROM page WHERE id IN (SELECT id FROM chain) ORDER BY sortKey, id
                """, arguments: arguments).map(Page.init(row:))
        })
    }
}
