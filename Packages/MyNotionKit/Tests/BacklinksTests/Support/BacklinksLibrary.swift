import Foundation
import GRDB
@testable import Backlinks
@testable import NotesCore
import Testing

/// Временная база с подключённым подписчиком обратных ссылок; стирается вместе с объектом.
final class BacklinksLibrary {
    let store: NotesStore
    private let folder: TemporaryFolder

    /// `indexBuilt` — отметка «индекс построен» уже стоит (новая база: строить нечего).
    init(indexBuilt: Bool = true) throws {
        folder = try TemporaryFolder()
        let database = try AppDatabase.open(at: folder.databaseURL)
        store = NotesStore(database: database, clock: HybridLogicalClock(deviceId: UUID()))
        store.addWriteHook(PageLinkIndexer())
        if indexBuilt { try store.setAppMeta(BacklinkIndexBuild.builtKey, "1") }
    }

    deinit {
        store.database.close()
    }

    var backlinks: Backlinks { Backlinks(store: store) }

    /// Страница с пустым абзацем.
    @discardableResult
    func page(_ title: String, parent: UUID? = nil, isTemplate: Bool = false) throws -> Page {
        try store.write { transaction in
            var page = try transaction.createPage(title: title, parentId: parent)
            if isTemplate {
                page.isTemplate = true
                page = try transaction.updatePage(page)
            }
            return page
        }
    }

    /// Абзац с упоминанием страницы `target` в конце текста.
    @discardableResult
    func addMention(of target: UUID, on pageId: UUID, text: String = "Смотри ") throws -> Block {
        try store.write { transaction in
            try transaction.insertBlock(Block(pageId: pageId, text: Self.text(text, mentioning: target), sortKey: Self.nextKey(on: pageId, transaction)))
        }
    }

    /// Блок-ссылка на страницу.
    @discardableResult
    func addPageLink(to target: UUID, on pageId: UUID) throws -> Block {
        try store.write { transaction in
            try transaction.insertBlock(Block(pageId: pageId, kind: .pageLink, linkedPageId: target, sortKey: Self.nextKey(on: pageId, transaction)))
        }
    }

    func eraseMention(in block: Block) throws {
        try store.write { transaction in
            var changed = try #require(try transaction.block(block.id))
            changed.text = InlineText("Смотри")
            try transaction.updateBlock(changed)
        }
    }

    func deleteBlock(_ id: UUID) throws {
        try store.write { try $0.deleteBlock(id) }
    }

    func trash(_ pageId: UUID) throws {
        try store.write { transaction in
            var page = try #require(try transaction.page(pageId))
            page.trashedAt = Date()
            try transaction.updatePage(page)
        }
    }

    /// Строки индекса целиком, по порядку: «блок → цель».
    func rows() throws -> [String] {
        try store.database.dbWriter.read { db in
            try Row.fetchAll(db, sql: "SELECT sourceBlockId, sourcePageId, targetPageId FROM page_link ORDER BY sourceBlockId, targetPageId")
                .map { "\($0["sourceBlockId"] as String)>\($0["targetPageId"] as String)@\($0["sourcePageId"] as String)" }
        }
    }

    /// База «до 003»: индекса ещё нет.
    func clearRows() throws {
        try store.database.dbWriter.write { try $0.execute(sql: "DELETE FROM page_link") }
    }

    func rowCount(target: UUID) throws -> Int {
        try store.database.dbWriter.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM page_link WHERE targetPageId = ?", arguments: [target.databaseText]) ?? 0
        }
    }

    static func text(_ prefix: String, mentioning target: UUID) -> InlineText {
        let start = (prefix as NSString).length
        return InlineText(prefix + "\u{FFFC}", runs: [StyledRun(start: start, length: 1, style: .mention(target))])
    }

    private static func nextKey(on pageId: UUID, _ transaction: NotesTransaction) throws -> FractionalSortKey {
        .between(try transaction.blocks(ofPage: pageId).map(\.sortKey).max(), nil)
    }
}

/// Пустая папка на время теста; стирается вместе с объектом.
final class TemporaryFolder: Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyNotionBacklinksTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    var databaseURL: URL { url.appendingPathComponent("MyNotion.sqlite") }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
