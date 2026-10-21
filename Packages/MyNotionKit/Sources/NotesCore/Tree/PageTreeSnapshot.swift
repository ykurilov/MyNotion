import Foundation
import GRDB

/// Дерево страниц на момент чтения, без корзины и без текста блоков.
/// Страница, чей родитель исчез, показывается в корне (data-model.md, «TrashEntry»).
/// Базы (004, research R1): дети страницы-базы (строки) и встроенные базы в дереве панели не видны, но находятся по id.
public struct PageTreeSnapshot: Sendable {
    private let pagesById: [UUID: Page]
    private let childrenByParent: [UUID?: [Page]]
    /// Страницы-базы: `true` — встроенная.
    private let databases: [UUID: Bool]

    public init(allPages: [Page], databases: [UUID: Bool] = [:]) {
        let byId = Dictionary(uniqueKeysWithValues: allPages.map { ($0.id, $0) })
        let visible = allPages.filter { !Self.isInTrash($0, pagesById: byId) }
        let visibleIds = Set(visible.map(\.id))
        pagesById = Dictionary(uniqueKeysWithValues: visible.map { ($0.id, $0) })
        self.databases = databases
        // В дереве: не встроенные базы, не строки баз и не то, что внутри строк.
        func isHidden(_ page: Page) -> Bool {
            if databases[page.id] == true { return true }
            var parent = page.parentId
            var steps = 0
            while let id = parent, steps <= byId.count {
                if databases[id] != nil { return true }
                parent = byId[id]?.parentId
                steps += 1
            }
            return false
        }
        let shown = databases.isEmpty ? visible : visible.filter { !isHidden($0) }
        childrenByParent = Dictionary(grouping: shown) { page in
            page.parentId.flatMap { visibleIds.contains($0) ? $0 : nil }
        }.mapValues { $0.sorted(by: Self.siblingOrder) }
    }

    /// Страница — база (полностраничная или встроенная).
    public func isDatabase(_ pageId: UUID) -> Bool { databases[pageId] != nil }

    /// Подстраницы по порядку в дереве панели; `nil` — корень.
    public func children(of parentId: UUID?) -> [Page] {
        childrenByParent[parentId] ?? []
    }

    public func page(_ id: UUID) -> Page? {
        pagesById[id]
    }

    public var visiblePageCount: Int { pagesById.count }

    /// Шаблоны (страницы с отметкой) по порядку дерева, без корзины. Шаблон с родителем после слияния правок
    /// двух Mac тоже здесь (data-model.md).
    public var templates: [Page] { pagesInTreeOrder.filter(\.isTemplate) }

    /// Дерево без шаблонов и их подстраниц: в «Страницах» шаблонов нет (US7, раздел «Шаблоны»).
    public func withoutTemplates() -> PageTreeSnapshot {
        guard pagesById.values.contains(where: \.isTemplate) else { return self }
        var kept: [Page] = []
        func appendBranch(_ page: Page) {
            guard !page.isTemplate else { return }
            kept.append(page)
            children(of: page.id).forEach(appendBranch)
        }
        children(of: nil).forEach(appendBranch)
        return PageTreeSnapshot(allPages: kept, databases: databases)
    }

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
        let outline = try treeOutline()
        return PageTreeSnapshot(allPages: outline.pages, databases: outline.databases)
    }

    /// Страницы для дерева панели (research R1): без строк баз и того, что внутри строк (их тысячи — дерево их не
    /// показывает и не читает), но с корзиной целиком; и какие страницы — базы (`true` — встроенная).
    public func treeOutline() throws -> (pages: [Page], databases: [UUID: Bool]) {
        try database.dbWriter.read { db in
            let pages = try Row.fetchAll(db, sql: Self.treeOutlineSQL).map(Page.init(row:))
            var databases: [UUID: Bool] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT pageId, isInline FROM db_database") {
                if let id = RowDecoding.optionalUUID(row, "pageId") { databases[id] = row["isInline"] }
            }
            return (pages, databases)
        }
    }

    /// Обход от корней по индексу `page_by_parent`, не спускаясь в базы: строк баз десятки тысяч, и полный проход
    /// по `page` на холодном диске стоил первому запуску 1,3 с (T030). Корни — страницы без родителя и сироты
    /// (родитель исчез): различных родителей перебирает «прыжок по индексу», не читая строки баз. Корзина — по
    /// частичному индексу `page_trashed`, с удалёнными строками баз.
    static let treeOutlineSQL = """
        WITH RECURSIVE
            parents(id) AS (
                SELECT min(parentId) FROM page WHERE parentId IS NOT NULL
                UNION ALL SELECT (SELECT min(parentId) FROM page WHERE parentId > parents.id) FROM parents WHERE parents.id IS NOT NULL),
            shown(id) AS (
                SELECT id FROM page WHERE parentId IS NULL
                UNION SELECT page.id FROM parents JOIN page ON page.parentId = parents.id
                    WHERE NOT EXISTS (SELECT 1 FROM page AS parent WHERE parent.id = parents.id)
                UNION SELECT page.id FROM shown JOIN page ON page.parentId = shown.id
                    WHERE shown.id NOT IN (SELECT pageId FROM db_database))
        SELECT * FROM page WHERE id IN shown
        UNION SELECT * FROM page WHERE trashedAt IS NOT NULL
        ORDER BY sortKey, id
        """

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
