import Foundation
import NotesCore

/// Подписчик ядра: держит `page_link` в той же транзакции, что и запись блоков (research R10), как поиск свой индекс.
/// Источник — блок с упоминанием «@» или ссылкой-подстраницей; ссылка родителя на своего ребёнка в индекс не пишется.
/// Что ушло в корзину или стало шаблоном, решает запрос (`Backlinks`), а не подписчик: строки остаются, пока жив блок.
/// После фиксации подписчик говорит, у каких страниц мог смениться счёт (`onLinksChange`): открытая страница
/// перечитывает «↗ N» сразу. Набор текста без смены ссылок сигнала не даёт.
public struct PageLinkIndexer: NotesWriteHook {
    private let onLinksChange: (@Sendable (BacklinkTargets) -> Void)?

    public init(onLinksChange: (@Sendable (BacklinkTargets) -> Void)? = nil) {
        self.onLinksChange = onLinksChange
    }

    public func notesWillCommit(_ changes: NotesChanges, in transaction: NotesTransaction) throws {
        var touched: Set<UUID> = []
        var erasedBlockIds: [UUID] = []
        for change in changes.blocks {
            switch change {
            case .saved(let block, let changedFields, let isNew) where isNew || !changedFields.isDisjoint(with: [.text, .kindAndIndent]):
                touched.formUnion(try reindex(block, in: transaction))
            case .saved:
                break
            case .erased(let blockId, _):
                erasedBlockIds.append(blockId)
            }
        }
        // Страница могла появиться после блока, который на неё ссылается: ссылка родителя на ребёнка — не обратная.
        for change in changes.pages where change.isNew || change.changedFields.contains(.placement) {
            touched.formUnion(try dropParentLink(to: change.page, in: transaction))
        }
        touched.formUnion(try delete(column: "sourceBlockId", ids: erasedBlockIds, in: transaction))
        touched.formUnion(try delete(column: "sourcePageId", ids: changes.erasedPageIds, in: transaction))
        touched.formUnion(try delete(column: "targetPageId", ids: changes.erasedPageIds, in: transaction))
        guard let onLinksChange else { return }
        // Корзина, шаблон и перенос меняют счёт у целей всего поддерева источника — проще перечитать все открытые.
        let touchesAll = changes.pages.contains { !$0.isNew && !$0.changedFields.isDisjoint(with: [.trashedAt, .isTemplate, .placement]) }
        if touchesAll {
            transaction.afterCommit { onLinksChange(.all) }
        } else if !touched.isEmpty {
            transaction.afterCommit { [touched] in onLinksChange(.pages(touched)) }
        }
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

    /// Возвращает цели, чьи строки ушли или появились.
    private func reindex(_ block: Block, in transaction: NotesTransaction) throws -> Set<UUID> {
        let id = SQLValue.text(block.id.linkIndexText)
        let targets = Self.targets(of: block)
        guard !targets.isEmpty else {
            // Блок без ссылок: строки, если были (упоминание стёрто), уходят; запрос по первичному ключу, на набор не влияет.
            return Self.pageIds(try transaction.fetchTexts(sql: "DELETE FROM page_link WHERE sourceBlockId = ? RETURNING targetPageId", arguments: [id]))
        }
        let marks = Array(repeating: "?", count: targets.count).joined(separator: ", ")
        var changed = try transaction.fetchTexts(sql: "DELETE FROM page_link WHERE sourceBlockId = ? AND targetPageId NOT IN (\(marks)) RETURNING targetPageId",
                                                 arguments: [id] + targets.map { .text($0.linkIndexText) })
        for target in targets where !(try isParentLinkToChild(block, target: target, in: transaction)) {
            // Уже стоявшая строка пропускается и в ответ не попадает.
            changed += try transaction.fetchTexts(sql: "INSERT OR IGNORE INTO page_link (sourceBlockId, sourcePageId, targetPageId) VALUES (?, ?, ?) RETURNING targetPageId",
                                                  arguments: [id, .text(block.pageId.linkIndexText), .text(target.linkIndexText)])
        }
        return Self.pageIds(changed)
    }

    private static func pageIds(_ texts: [String]) -> Set<UUID> {
        Set(texts.compactMap(UUID.init(uuidString:)))
    }

    /// Ссылка-подстраница на страницу, чей родитель — страница самого блока.
    private func isParentLinkToChild(_ block: Block, target: UUID, in transaction: NotesTransaction) throws -> Bool {
        guard block.kind == .pageLink, block.linkedPageId == target else { return false }
        return try transaction.page(target)?.parentId == block.pageId
    }

    private func dropParentLink(to page: Page, in transaction: NotesTransaction) throws -> Set<UUID> {
        guard let parentId = page.parentId else { return [] }
        return Self.pageIds(try transaction.fetchTexts(sql: """
            DELETE FROM page_link WHERE targetPageId = ? AND sourcePageId = ?
                AND sourceBlockId IN (SELECT id FROM block WHERE kind = 'pageLink' AND linkedPageId = ?)
            RETURNING targetPageId
            """, arguments: [.text(page.id.linkIndexText), .text(parentId.linkIndexText), .text(page.id.linkIndexText)]))
    }

    private func delete(column: String, ids: [UUID], in transaction: NotesTransaction) throws -> Set<UUID> {
        guard !ids.isEmpty else { return [] }
        let marks = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        return Self.pageIds(try transaction.fetchTexts(sql: "DELETE FROM page_link WHERE \(column) IN (\(marks)) RETURNING targetPageId",
                                                       arguments: ids.map { .text($0.linkIndexText) }))
    }
}

/// Чьи обратные ссылки могли смениться после записи.
public enum BacklinkTargets: Sendable, Hashable {
    case pages(Set<UUID>)
    /// Источник ушёл в корзину, вернулся, стал шаблоном или переехал — перечитать все открытые страницы.
    case all
}

extension UUID {
    /// Как id лежат в базе: строка UUID в нижнем регистре.
    var linkIndexText: String { uuidString.lowercased() }
}
