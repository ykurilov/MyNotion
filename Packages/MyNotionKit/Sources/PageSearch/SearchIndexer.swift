import Foundation
import NotesCore

/// Подписчик ядра: держит `search_index` в той же транзакции, что и запись названий и текста блоков (research R6).
/// Строка названия — rowid `-page.rowid` без blockId, строка блока — rowid `block.rowid`: правка находит свою строку
/// без перебора индекса. Пустые названия и блоки не индексируются. Корзина не трогается — её отсекает выдача.
public struct SearchIndexer: NotesWriteHook {
    public init() {}

    public func notesWillCommit(_ changes: NotesChanges, in transaction: NotesTransaction) throws {
        for change in changes.pages where change.isNew || change.changedFields.contains(.title) {
            try reindexTitle(of: change.page, in: transaction)
        }
        var erasedBlockIds: [UUID] = []
        for change in changes.blocks {
            switch change {
            case .saved(let block, let changedFields, let isNew) where isNew || changedFields.contains(.text):
                try reindexText(of: block, in: transaction)
            case .saved:
                break
            case .erased(let blockId, _):
                erasedBlockIds.append(blockId)
            }
        }
        // Стёртых строк в таблицах уже нет — их строки индекса ищутся по id.
        try delete(column: "blockId", ids: erasedBlockIds, in: transaction)
        try delete(column: "pageId", ids: changes.erasedPageIds, in: transaction)
    }

    private func reindexTitle(of page: Page, in transaction: NotesTransaction) throws {
        let id = SQLValue.text(page.id.searchIndexText)
        try transaction.execute(sql: "DELETE FROM search_index WHERE rowid = -(SELECT rowid FROM page WHERE id = ?)", arguments: [id])
        guard !page.title.isEmpty else { return }
        try transaction.execute(sql: """
            INSERT INTO search_index (rowid, pageId, blockId, content) SELECT -rowid, id, NULL, ? FROM page WHERE id = ?
            """, arguments: [.text(SearchText.indexed(page.title)), id])
    }

    private func reindexText(of block: Block, in transaction: NotesTransaction) throws {
        let id = SQLValue.text(block.id.searchIndexText)
        try transaction.execute(sql: "DELETE FROM search_index WHERE rowid = (SELECT rowid FROM block WHERE id = ?)", arguments: [id])
        guard !block.text.string.isEmpty else { return }
        try transaction.execute(sql: """
            INSERT INTO search_index (rowid, pageId, blockId, content) SELECT rowid, pageId, id, ? FROM block WHERE id = ?
            """, arguments: [.text(SearchText.indexed(block.text.string)), id])
    }

    private func delete(column: String, ids: [UUID], in transaction: NotesTransaction) throws {
        guard !ids.isEmpty else { return }
        let marks = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        try transaction.execute(sql: "DELETE FROM search_index WHERE \(column) IN (\(marks))",
                                arguments: ids.map { .text($0.searchIndexText) })
    }
}

extension UUID {
    /// Как id лежат в базе: строка UUID в нижнем регистре.
    var searchIndexText: String { uuidString.lowercased() }
}
