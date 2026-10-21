import Foundation
import GRDB

/// Страница-база в редакторе (US1, T041): своих блоков у неё нет (её содержимое — строки), поэтому открытый документ
/// показывает один блок `database`, который ссылается на саму базу: таблица на всю страницу под её шапкой (название,
/// иконка, обложка 003). Блок не записывается — его нет в хранилище, тело страницы-базы не правится.
public enum DatabasePageContent {
    static let namespace = UUID(uuidString: "6F1C4D52-5A0E-4E59-9B0A-2A7D4C0B0006")!

    /// Id блока таблицы страницы-базы — один и тот же на всех Mac и при каждом открытии.
    public static func blockId(of databaseId: UUID) -> UUID {
        DerivedID.make(namespace: namespace, name: databaseId.databaseText)
    }

    /// Блок `database` — таблица на всю страницу (ссылается на свою же страницу), а не встроенная база.
    public static func isFullPage(_ block: Block) -> Bool {
        block.kind == .database && block.linkedPageId == block.pageId
    }

    /// Содержимое страницы для редактора: у страницы-базы — один блок таблицы.
    static func presenting(_ content: PageContent, in database: AppDatabase) throws -> PageContent {
        let pageId = content.page.id
        let isDatabase = try database.dbWriter.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM db_database WHERE pageId = ?)", arguments: [pageId.databaseText]) ?? false
        }
        guard isDatabase else { return content }
        let block = Block(id: blockId(of: pageId), pageId: pageId, kind: .database, linkedPageId: pageId, sortKey: .between(nil, nil))
        // Страница-база — во всю ширину окна, как у Notion 7.39; документ сравнивает с тем же, поэтому не записывает.
        var page = content.page
        page.isFullWidth = true
        return PageContent(page: page, blocks: [block])
    }
}
