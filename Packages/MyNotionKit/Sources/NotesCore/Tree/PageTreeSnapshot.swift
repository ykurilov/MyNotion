import Foundation
import GRDB

/// Дерево страниц на момент чтения, без корзины и без текста блоков.
/// Страница, чей родитель исчез, показывается в корне (data-model.md, «TrashEntry»).
public struct PageTreeSnapshot: Sendable {
    private let pagesById: [UUID: Page]
    private let childrenByParent: [UUID?: [Page]]

    public init(allPages: [Page]) {
        let byId = Dictionary(uniqueKeysWithValues: allPages.map { ($0.id, $0) })
        let visible = allPages.filter { !Self.isInTrash($0, pagesById: byId) }
        let visibleIds = Set(visible.map(\.id))
        pagesById = Dictionary(uniqueKeysWithValues: visible.map { ($0.id, $0) })
        childrenByParent = Dictionary(grouping: visible) { page in
            page.parentId.flatMap { visibleIds.contains($0) ? $0 : nil }
        }.mapValues { $0.sorted(by: Self.siblingOrder) }
    }

    /// Подстраницы по порядку; `nil` — корень.
    public func children(of parentId: UUID?) -> [Page] {
        childrenByParent[parentId] ?? []
    }

    public func page(_ id: UUID) -> Page? {
        pagesById[id]
    }

    public var visiblePageCount: Int { pagesById.count }

    /// Родитель в дереве: `nil` у корня и у страницы, чей родитель исчез.
    public func parentId(of pageId: UUID) -> UUID? {
        pagesById[pageId]?.parentId.flatMap { pagesById[$0] == nil ? nil : $0 }
    }

    /// Предки страницы от корня.
    public func ancestors(of pageId: UUID) -> [Page] {
        var result: [Page] = []
        var current = parentId(of: pageId)
        while let id = current, let parent = pagesById[id], result.count < pagesById.count {
            result.insert(parent, at: 0)
            current = parentId(of: id)
        }
        return result
    }

    /// `candidate` — сама страница или лежит внутри неё.
    public func isPage(_ candidate: UUID, insideBranchOf pageId: UUID) -> Bool {
        candidate == pageId || ancestors(of: candidate).contains { $0.id == pageId }
    }

    /// Все страницы в порядке дерева: родитель, затем его ветка.
    public var pagesInTreeOrder: [Page] {
        var ordered: [Page] = []
        func appendBranch(_ parentId: UUID?) {
            for page in children(of: parentId) {
                ordered.append(page)
                appendBranch(page.id)
            }
        }
        appendBranch(nil)
        return ordered
    }

    static func siblingOrder(_ lhs: Page, _ rhs: Page) -> Bool {
        lhs.sortKey != rhs.sortKey ? lhs.sortKey < rhs.sortKey : lhs.id.uuidString < rhs.id.uuidString
    }

    /// Страница в корзине сама или вместе с кем-то из предков.
    static func isInTrash(_ page: Page, pagesById: [UUID: Page]) -> Bool {
        var current: Page? = page
        var steps = 0
        while let checked = current, steps <= pagesById.count {
            if checked.trashedAt != nil { return true }
            current = checked.parentId.flatMap { pagesById[$0] }
            steps += 1
        }
        return false
    }
}

/// Надгробие стёртой навсегда страницы: для синхронизации (research R8).
public struct PageTombstone: Sendable, Hashable {
    public let pageId: UUID
    public let erasedAt: HybridTimestamp
}

extension NotesStore {
    /// Дерево без корзины.
    public func pageTree() throws -> PageTreeSnapshot {
        PageTreeSnapshot(allPages: try pageOutline())
    }

    /// Записи корзины: страницы в корзине, чей родитель не в корзине; последние удалённые — сверху.
    public func trashEntries() throws -> [Page] {
        let all = try pageOutline()
        return Self.trashEntries(in: all)
    }

    /// Записи корзины среди уже прочитанных страниц.
    public static func trashEntries(in all: [Page]) -> [Page] {
        let byId = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        return all.filter { page in
            guard page.trashedAt != nil else { return false }
            guard let parent = page.parentId.flatMap({ byId[$0] }) else { return true }
            return !PageTreeSnapshot.isInTrash(parent, pagesById: byId)
        }.sorted { ($0.trashedAt ?? .distantPast) > ($1.trashedAt ?? .distantPast) }
    }

    public func pageTombstones() throws -> [PageTombstone] {
        try database.dbWriter.read { db in
            try Row.fetchAll(db, sql: "SELECT pageId, erasedAt FROM page_tombstone ORDER BY erasedAt").compactMap { row in
                guard let pageId = RowDecoding.optionalUUID(row, "pageId"),
                      let erasedAt = HybridTimestamp(row["erasedAt"] as String) else { return nil }
                return PageTombstone(pageId: pageId, erasedAt: erasedAt)
            }
        }
    }
}
