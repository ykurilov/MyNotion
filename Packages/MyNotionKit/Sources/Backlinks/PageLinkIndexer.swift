import Foundation
import NotesCore

/// Подписчик ядра: держит `page_link` в той же транзакции, что и запись блоков (research R10), как поиск свой индекс.
/// Источник — блок с упоминанием «@» или ссылкой-подстраницей; ссылка родителя на своего ребёнка в индекс не пишется.
/// Что ушло в корзину или стало шаблоном, решает запрос (`Backlinks`), а не подписчик: строки остаются, пока жив блок.
public struct PageLinkIndexer: NotesWriteHook {
    public init() {}

    public func notesWillCommit(_ changes: NotesChanges, in transaction: NotesTransaction) throws {
        var erasedBlockIds: [UUID] = []
        for change in changes.blocks {
            switch change {
            case .saved(let block, let changedFields, let isNew) where isNew || !changedFields.isDisjoint(with: [.text, .kindAndIndent]):
                try reindex(block, in: transaction)
            case .saved:
                break
            case .erased(let blockId, _):
                erasedBlockIds.append(blockId)
            }
        }
        // Страница могла появиться после блока, который на неё ссылается: ссылка родителя на ребёнка — не обратная.
        for change in changes.pages where change.isNew || change.changedFields.contains(.placement) {
            try dropParentLink(to: change.page, in: transaction)
        }
        try delete(column: "sourceBlockId", ids: erasedBlockIds, in: transaction)
        try delete(column: "sourcePageId", ids: changes.erasedPageIds, in: transaction)
        try delete(column: "targetPageId", ids: changes.erasedPageIds, in: transaction)
    }

    /// Цели блока: страницы его упоминаний и, у ссылки-подстраницы, страница ссылки.
    static func targets(of block: Block) -> Set<UUID> {
        var targets: Set<UUID> = []
        for run in block.text.runs {
            if case .mention(let pageId) = run.style { targets.insert(pageId) }
        }
        if block.kind == .pageLink, let linked = block.linkedPageId { targets.insert(linked) }
        return targets
    }

    private func reindex(_ block: Block, in transaction: NotesTransaction) throws {
        let id = SQLValue.text(block.id.linkIndexText)
        let targets = Self.targets(of: block)
        guard !targets.isEmpty else {
            // Блок без ссылок: строки, если были (упоминание стёрто), уходят; запрос по первичному ключу, на набор не влияет.
            try transaction.execute(sql: "DELETE FROM page_link WHERE sourceBlockId = ?", arguments: [id])
            return
        }
        let marks = Array(repeating: "?", count: targets.count).joined(separator: ", ")
        try transaction.execute(sql: "DELETE FROM page_link WHERE sourceBlockId = ? AND targetPageId NOT IN (\(marks))",
                                arguments: [id] + targets.map { .text($0.linkIndexText) })
        for target in targets where !(try isParentLinkToChild(block, target: target, in: transaction)) {
            try transaction.execute(sql: "INSERT OR IGNORE INTO page_link (sourceBlockId, sourcePageId, targetPageId) VALUES (?, ?, ?)",
                                    arguments: [id, .text(block.pageId.linkIndexText), .text(target.linkIndexText)])
        }
    }

    /// Ссылка-подстраница на страницу, чей родитель — страница самого блока.
    private func isParentLinkToChild(_ block: Block, target: UUID, in transaction: NotesTransaction) throws -> Bool {
        guard block.kind == .pageLink, block.linkedPageId == target else { return false }
        return try transaction.page(target)?.parentId == block.pageId
    }

    private func dropParentLink(to page: Page, in transaction: NotesTransaction) throws {
        guard let parentId = page.parentId else { return }
        try transaction.execute(sql: """
            DELETE FROM page_link WHERE targetPageId = ? AND sourcePageId = ?
                AND sourceBlockId IN (SELECT id FROM block WHERE kind = 'pageLink' AND linkedPageId = ?)
            """, arguments: [.text(page.id.linkIndexText), .text(parentId.linkIndexText), .text(page.id.linkIndexText)])
    }

    private func delete(column: String, ids: [UUID], in transaction: NotesTransaction) throws {
        guard !ids.isEmpty else { return }
        let marks = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        try transaction.execute(sql: "DELETE FROM page_link WHERE \(column) IN (\(marks))", arguments: ids.map { .text($0.linkIndexText) })
    }
}

extension UUID {
    /// Как id лежат в базе: строка UUID в нижнем регистре.
    var linkIndexText: String { uuidString.lowercased() }
}
