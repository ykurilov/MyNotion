import Foundation

/// Операции с деревом страниц (FR-001…FR-005, FR-012). Каждая — одна транзакция хранилища,
/// поэтому подписчики (поиск, синхронизация) видят страницу и ссылку на неё в родителе вместе.
/// Отмена ставится в `undoManager` окна; удаление навсегда не отменяется.
@MainActor
public final class PageTreeOperations {
    public let store: NotesStore
    /// Отмена окна: ⌘Z / ⇧⌘Z общие с редактором.
    public weak var undoManager: UndoManager?
    /// После каждой успешной операции, в том числе отмены: какие страницы она затронула.
    public var onChange: ((Set<UUID>) -> Void)?
    /// Иконка страницы сменилась (в том числе отменой): страница и новая иконка. Вместо `onChange`, чтобы окно
    /// не перечитывало открытую страницу, а только подставило иконку.
    public var onIconChange: ((UUID, String?) -> Void)?
    /// Отмена не удалась (например, страницу уже стёрли навсегда).
    public var onUndoFailure: ((any Error) -> Void)?

    public init(store: NotesStore, undoManager: UndoManager? = nil) {
        self.store = store
        self.undoManager = undoManager
    }

    // MARK: Создать, переименовать

    /// Подстраница — пара: страница с `parentId` последней среди соседей и блок-ссылка в конце родителя.
    @discardableResult
    public func createSubpage(in parentId: UUID, title: String = "") throws -> Page {
        let page = try perform { transaction in
            guard try transaction.page(parentId) != nil else { throw NotesStoreError.pageNotFound(parentId) }
            let page = try transaction.createPage(title: title, parentId: parentId)
            try Self.appendLink(to: page.id, in: parentId, transaction)
            return page
        }
        // Отмена создания уводит страницу в корзину: набранное в ней за это время не пропадает.
        registerUndo("Новая подстраница") { try $0.moveToTrash(page.id) }
        return page
    }

    /// «/» → «Страница», как в Notion 7.39: подстраница с блоком-ссылкой там, где курсор, а не в конце родителя.
    /// В дереве она встаёт по порядку ссылок: сразу за соседом, чья ссылка выше, или перед тем, чья ниже.
    /// Отмена — один шаг: страница уходит в корзину (набранное в ней цело), убранный блок возвращается на место.
    @discardableResult
    public func createSubpage(in parentId: UUID, title: String = "", linkAt placement: SubpageLinkPlacement) throws -> Page {
        try createSubpage(in: parentId, linkAt: placement) { _ in title }
    }

    /// «Преобразовать в → Страница», как в Notion: блок становится ссылкой на подстраницу с его текстом в названии,
    /// вложенные под ним блоки переезжают внутрь (со своими колонками, таблицами и подстраницами).
    /// Страница не открывается; ⌘Z одним шагом возвращает блок с детьми на место.
    @discardableResult
    public func turnIntoSubpage(_ blockId: UUID, in pageId: UUID) throws -> Page {
        try createSubpage(in: pageId, linkAt: .replacing(blockId: blockId), movesChildren: true) { block in
            block.text.string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func createSubpage(
        in parentId: UUID, linkAt placement: SubpageLinkPlacement, movesChildren: Bool = false, title: (Block) -> String
    ) throws -> Page {
        let created = try perform { transaction in
            guard try transaction.page(parentId) != nil else { throw NotesStoreError.pageNotFound(parentId) }
            let blocks = try transaction.blocks(ofPage: parentId)
            guard let anchor = blocks.first(where: { $0.id == placement.blockId }) else {
                throw NotesStoreError.blockNotFound(placement.blockId)
            }
            let placed = Self.linkPlacement(at: placement, anchor: anchor, in: blocks)
            let siblings = try transaction.allPages().filter { $0.parentId == parentId && $0.trashedAt == nil }
            let pageKey = Self.subpageSortKey(linkedAfter: placed.preceding, in: Self.documentOrder(blocks), siblings: siblings)
            let page = try transaction.createPage(title: title(anchor), parentId: parentId, after: pageKey.after, before: pageKey.before)
            var link = Block(pageId: parentId, kind: .pageLink, linkedPageId: page.id, sortKey: placed.sortKey)
            link.indent = anchor.indent
            link.containerId = anchor.containerId
            let children = movesChildren ? try Self.moveChildren(of: anchor, in: blocks, into: page.id, transaction) : ChildrenMove()
            if placement.replaces { try transaction.deleteBlock(anchor.id) }
            let inserted = try transaction.insertBlock(link)
            return InlineSubpage(page: page, link: inserted, replaced: placement.replaces ? anchor : nil, children: children)
        }
        try moveCollapsed(created.children.copiedIds)
        registerUndo("Новая подстраница") { try $0.withdraw(created) }
        return created.page
    }

    public func rename(_ pageId: UUID, to title: String) throws {
        let oldTitle = try perform { transaction in
            guard var page = try transaction.page(pageId) else { throw NotesStoreError.pageNotFound(pageId) }
            let oldTitle = page.title
            page.title = title
            try transaction.updatePage(page)
            return oldTitle
        }
        guard oldTitle != title else { return }
        registerUndo("Переименование") { try $0.rename(pageId, to: oldTitle) }
    }

    /// Поставить, сменить или убрать (`nil`) иконку-эмодзи (FR-034): одна правка поля `icon`.
    public func setIcon(_ pageId: UUID, to icon: String?) throws {
        let oldIcon = try perform(notify: false) { transaction in
            guard var page = try transaction.page(pageId) else { throw NotesStoreError.pageNotFound(pageId) }
            let oldIcon = page.icon
            guard oldIcon != icon else { return oldIcon }
            page.icon = icon
            try transaction.updatePage(page)
            return oldIcon
        }
        guard oldIcon != icon else { return }
        onIconChange?(pageId, icon)
        registerUndo("Иконка страницы") { try $0.setIcon(pageId, to: oldIcon) }
    }

    // MARK: Перенос

    /// Можно ли положить страницу внутрь `parentId` (`nil` — в корень): не в себя и не в свою ветку.
    public func canMove(_ pageId: UUID, toParent parentId: UUID?) throws -> Bool {
        guard let parentId else { return true }
        let tree = try store.pageTree()
        return tree.page(parentId) != nil && !tree.isPage(parentId, insideBranchOf: pageId)
    }

    /// Перенести страницу с веткой внутрь `parentId` (`nil` — корень) на место `index` среди новых соседей.
    public func move(_ pageId: UUID, toParent parentId: UUID?, at index: Int) throws {
        try place(pageId, actionName: "Перенос страницы") { transaction in
            let tree = PageTreeSnapshot(allPages: try transaction.allPages())
            if let parentId {
                guard tree.page(parentId) != nil else { throw NotesStoreError.pageNotFound(parentId) }
                guard !tree.isPage(parentId, insideBranchOf: pageId) else {
                    throw NotesStoreError.invalidPage("страница не может лежать внутри себя или своей подстраницы")
                }
            }
            let siblings = tree.children(of: parentId).filter { $0.id != pageId }
            let position = min(max(index, 0), siblings.count)
            let previous = position > 0 ? siblings[position - 1].sortKey : nil
            var next = position < siblings.count ? siblings[position].sortKey : nil
            if let previous, let nextKey = next, !(previous < nextKey) { next = nil }
            return (parentId, FractionalSortKey.between(previous, next))
        }
    }

    // MARK: Корзина

    /// В корзину — вместе с подстраницами; ссылка из родителя убирается.
    public func moveToTrash(_ pageId: UUID) throws {
        let didTrash = try perform { transaction in
            guard var page = try transaction.page(pageId) else { throw NotesStoreError.pageNotFound(pageId) }
            guard page.trashedAt == nil else { return false }
            page.trashedAt = Date()
            try transaction.updatePage(page)
            if let parentId = page.parentId {
                try Self.removeLinks(to: pageId, in: parentId, transaction)
            }
            return true
        }
        if didTrash { registerUndo("Удаление в корзину") { try $0.restore(pageId) } }
    }

    /// Вернуть из корзины на прежнее место; если родитель исчез — в корень.
    public func restore(_ pageId: UUID) throws {
        try perform { transaction in
            guard var page = try transaction.page(pageId) else { throw NotesStoreError.pageNotFound(pageId) }
            guard page.trashedAt != nil else { throw NotesStoreError.invalidPage("страницы нет в корзине") }
            page.trashedAt = nil
            if let parentId = page.parentId, try transaction.page(parentId) == nil {
                let lastRootKey = try transaction.allPages().filter { $0.parentId == nil }.map(\.sortKey).max()
                page.parentId = nil
                page.sortKey = .between(lastRootKey, nil)
            }
            try transaction.updatePage(page)
            if let parentId = page.parentId {
                try Self.appendLink(to: pageId, in: parentId, transaction)
            }
        }
        registerUndo("Возврат из корзины") { try $0.moveToTrash(pageId) }
    }

    /// Стереть страницу из корзины вместе с веткой; остаются надгробия. Не отменяется.
    /// Подстраница, которую удалили в корзину отдельно раньше, остаётся в корзине своей записью.
    public func deleteForever(_ pageId: UUID) throws {
        try perform { transaction in
            let all = try transaction.allPages()
            let byId = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
            guard let page = byId[pageId] else { throw NotesStoreError.pageNotFound(pageId) }
            guard PageTreeSnapshot.isInTrash(page, pagesById: byId) else {
                throw NotesStoreError.invalidPage("навсегда удаляется только страница из корзины")
            }
            let children = Dictionary(grouping: all, by: \.parentId)
            var branch: [Page] = []
            func collect(_ page: Page) {
                branch.append(page)
                for child in children[page.id] ?? [] where child.trashedAt == nil {
                    collect(child)
                }
            }
            collect(page)
            try Self.erase(branch, transaction)
        }
    }

    /// Стереть всё, что в корзине, одной транзакцией.
    public func emptyTrash() throws {
        try perform { transaction in
            let all = try transaction.allPages()
            let byId = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
            try Self.erase(all.filter { PageTreeSnapshot.isInTrash($0, pagesById: byId) }, transaction)
        }
    }

    // MARK: Внутреннее

    /// Что сделала «Страница» из «/»: для отмены и возврата.
    private struct InlineSubpage {
        let page: Page
        let link: Block
        /// Блок, на месте которого встала ссылка; `nil` — ссылка встала за блоком.
        let replaced: Block?
        var children = ChildrenMove()
    }

    /// Что переехало внутрь новой подстраницы при «Преобразовать в»: для отмены и возврата.
    private struct ChildrenMove {
        /// Дети и всё в их контейнерах, как лежали в родителе (сначала контейнер, потом его потоки).
        var originals: [Block] = []
        /// Копии ссылок на переехавшие подстраницы — в новой странице.
        var linkCopies: [Block] = []
        /// id переехавших блоков: прежний → новый (свёрнутость переключателей едет за ними).
        var copiedIds: [UUID: UUID] = [:]
        /// Переехавшие подстраницы: прежнее и новое место.
        var reparented: [(pageId: UUID, from: (parentId: UUID?, sortKey: FractionalSortKey), to: FractionalSortKey)] = []
    }

    /// Отмена «Страницы» из «/»: подстраница — в корзину, ссылка убрана, прежний блок с детьми — на месте,
    /// переехавшие подстраницы — у прежнего родителя.
    private func withdraw(_ created: InlineSubpage) throws {
        try perform { transaction in
            for moved in created.children.reparented {
                guard var page = try transaction.page(moved.pageId) else { continue }
                (page.parentId, page.sortKey) = moved.from
                try transaction.updatePage(page)
            }
            for copy in created.children.linkCopies where try transaction.block(copy.id) != nil {
                try transaction.deleteBlock(copy.id)
            }
            for original in created.children.originals where try transaction.block(original.id) == nil {
                try transaction.insertBlock(original)
            }
            guard var page = try transaction.page(created.page.id) else { throw NotesStoreError.pageNotFound(created.page.id) }
            page.trashedAt = Date()
            try transaction.updatePage(page)
            try Self.removeLinks(to: page.id, in: created.link.pageId, transaction)
            if let replaced = created.replaced, try transaction.block(replaced.id) == nil {
                try transaction.insertBlock(replaced)
            }
        }
        try moveCollapsed(Dictionary(uniqueKeysWithValues: created.children.copiedIds.map { ($1, $0) }))
        registerUndo("Новая подстраница") { try $0.reinstate(created) }
    }

    /// Возврат «Страницы» из «/»: подстраница из корзины, ссылка — на прежнем месте тем же блоком.
    private func reinstate(_ created: InlineSubpage) throws {
        try perform { transaction in
            guard var page = try transaction.page(created.page.id) else { throw NotesStoreError.pageNotFound(created.page.id) }
            page.trashedAt = nil
            try transaction.updatePage(page)
            if let replaced = created.replaced, try transaction.block(replaced.id) != nil {
                try transaction.deleteBlock(replaced.id)
            }
            for original in created.children.originals where try transaction.block(original.id) != nil {
                try transaction.deleteBlock(original.id)
            }
            for copy in created.children.linkCopies where try transaction.block(copy.id) == nil {
                try transaction.insertBlock(copy)
            }
            for moved in created.children.reparented {
                guard var subpage = try transaction.page(moved.pageId) else { continue }
                (subpage.parentId, subpage.sortKey) = (page.id, moved.to)
                try transaction.updatePage(subpage)
            }
            if try !transaction.blocks(ofPage: created.link.pageId).contains(where: { $0.linkedPageId == page.id }) {
                try transaction.insertBlock(created.link)
            }
        }
        try moveCollapsed(created.children.copiedIds)
        registerUndo("Новая подстраница") { try $0.withdraw(created) }
    }

    /// Дети блока — следующие за ним в его потоке блоки с отступом больше — переезжают в начало новой страницы
    /// копиями с новыми id: вложенность между собой, типы, цвет, данные (файлы, адреса) те же, контейнеры
    /// (колонки, таблицы) — со своими потоками. Подстраницы, чьи ссылки среди детей, переезжают под новую страницу.
    private static func moveChildren(of anchor: Block, in blocks: [Block], into pageId: UUID,
                                     _ transaction: NotesTransaction) throws -> ChildrenMove {
        let flow = blocks.filter { $0.containerId == anchor.containerId }.sorted(by: flowOrder)
        guard let index = flow.firstIndex(where: { $0.id == anchor.id }) else { return ChildrenMove() }
        let children = flow[(index + 1)...].prefix { $0.indent > anchor.indent }
        guard !children.isEmpty else { return ChildrenMove() }
        let copy = BlockCopier.copy(Array(children), pageBlocks: blocks, into: pageId, indentBase: anchor.indent + 1)
        var move = ChildrenMove()
        move.originals = copy.originals
        let copies = copy.blocks
        let newIds = copy.newIds
        move.copiedIds = newIds

        for original in move.originals.reversed() { try transaction.deleteBlock(original.id) }
        for block in try transaction.blocks(ofPage: pageId) { try transaction.deleteBlock(block.id) }
        var pageKey: FractionalSortKey?
        for copied in copies {
            try transaction.insertBlock(copied)
            guard let linked = copied.linkedPageId, var subpage = try transaction.page(linked),
                  subpage.parentId == anchor.pageId else { continue }
            pageKey = .between(pageKey, nil)
            move.reparented.append((linked, (subpage.parentId, subpage.sortKey), pageKey!))
            move.linkCopies.append(copied)
            (subpage.parentId, subpage.sortKey) = (pageId, pageKey!)
            try transaction.updatePage(subpage)
        }
        return move
    }

    /// Свёрнутость — вид этого Mac, мимо транзакций и отмены (research R1): переносится следом за правкой.
    private func moveCollapsed(_ oldToNew: [UUID: UUID]) throws {
        try BlockViewStateStore(database: store.database).moveCollapsed(from: oldToNew)
    }

    /// Ключ ссылки и блок, за которым она встаёт в документе (`nil` — первой).
    private static func linkPlacement(
        at placement: SubpageLinkPlacement, anchor: Block, in blocks: [Block]
    ) -> (sortKey: FractionalSortKey, preceding: Block?) {
        let flow = blocks.filter { $0.containerId == anchor.containerId }.sorted(by: flowOrder)
        let index = flow.firstIndex { $0.id == anchor.id } ?? 0
        if placement.replaces {
            return (anchor.sortKey, index > 0 ? flow[index - 1] : nil)
        }
        let next = index + 1 < flow.count ? flow[index + 1].sortKey : nil
        return (.between(anchor.sortKey, next), anchor)
    }

    /// Место подстраницы среди соседей в дереве: за соседом, чья ссылка ближе выше в документе, иначе перед тем,
    /// чья ссылка ниже; без ссылок у соседей — последней.
    private static func subpageSortKey(
        linkedAfter preceding: Block?, in ordered: [Block], siblings: [Page]
    ) -> (after: FractionalSortKey?, before: FractionalSortKey?) {
        let siblingKeys = Dictionary(uniqueKeysWithValues: siblings.map { ($0.id, $0.sortKey) })
        let cut = preceding.flatMap { block in ordered.firstIndex { $0.id == block.id } }.map { $0 + 1 } ?? 0
        let keys = siblingKeys.values.sorted()
        if let above = ordered[..<cut].reversed().lazy.compactMap({ $0.linkedPageId.flatMap { siblingKeys[$0] } }).first {
            return (above, keys.first { above < $0 })
        }
        if let below = ordered[cut...].lazy.compactMap({ $0.linkedPageId.flatMap { siblingKeys[$0] } }).first {
            return (keys.last { $0 < below }, below)
        }
        return (keys.last, nil)
    }

    /// Блоки страницы в порядке чтения: поток страницы, внутри контейнера (колонки, таблицы) — его потоки.
    private static func documentOrder(_ blocks: [Block]) -> [Block] {
        let flows = Dictionary(grouping: blocks, by: \.containerId).mapValues { $0.sorted(by: flowOrder) }
        var ordered: [Block] = []
        var visited: Set<UUID> = []
        func walk(_ containerId: UUID?) {
            for block in flows[containerId] ?? [] where visited.insert(block.id).inserted {
                ordered.append(block)
                walk(block.id)
            }
        }
        walk(nil)
        return ordered
    }

    private static func flowOrder(_ lhs: Block, _ rhs: Block) -> Bool {
        BlockCopier.flowOrder(lhs, rhs)
    }

    /// Новое место страницы; отмена ставит её точно на прежнее.
    private func place(
        _ pageId: UUID,
        actionName: String,
        _ newPlacement: (NotesTransaction) throws -> (parentId: UUID?, sortKey: FractionalSortKey)
    ) throws {
        let old = try perform { transaction in
            guard let page = try transaction.page(pageId) else { throw NotesStoreError.pageNotFound(pageId) }
            let placement = try newPlacement(transaction)
            var moved = page
            moved.parentId = placement.parentId
            moved.sortKey = placement.sortKey
            try transaction.updatePage(moved)
            if page.parentId != placement.parentId {
                if let oldParentId = page.parentId {
                    try Self.removeLinks(to: pageId, in: oldParentId, transaction)
                }
                if let newParentId = placement.parentId {
                    try Self.appendLink(to: pageId, in: newParentId, transaction)
                }
            }
            return (page.parentId, page.sortKey)
        }
        registerUndo(actionName) { operations in
            try operations.place(pageId, actionName: actionName) { _ in old }
        }
    }

    /// Одна транзакция; после неё — набор затронутых страниц для окна (`notify: false` — без `onChange`).
    /// Истории пишут свои операции в файлах-расширениях `PageTreeOperations+<Тема>.swift` через `perform` и `registerUndo`.
    @discardableResult
    func perform<T>(notify: Bool = true, _ body: (NotesTransaction) throws -> T) throws -> T {
        var touched: Set<UUID> = []
        let result = try store.write { transaction in
            let result = try body(transaction)
            let changes = transaction.changes
            touched.formUnion(changes.pages.map(\.page.id))
            touched.formUnion(changes.erasedPageIds)
            for change in changes.blocks {
                switch change {
                case .saved(let block, _, _): touched.insert(block.pageId)
                case .erased(_, let pageId): touched.insert(pageId)
                }
            }
            return result
        }
        if notify { onChange?(touched) }
        return result
    }

    func registerUndo(_ actionName: String, _ inverse: @escaping @MainActor (PageTreeOperations) throws -> Void) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { operations in
            MainActor.assumeIsolated {
                do {
                    try inverse(operations)
                } catch {
                    operations.onUndoFailure?(error)
                }
            }
        }
        undoManager.setActionName(actionName)
    }

    private static func appendLink(to pageId: UUID, in parentId: UUID, _ transaction: NotesTransaction) throws {
        let blocks = try transaction.blocks(ofPage: parentId)
        guard !blocks.contains(where: { $0.linkedPageId == pageId }) else { return }
        try transaction.insertBlock(Block(
            pageId: parentId, kind: .pageLink, linkedPageId: pageId, sortKey: .between(blocks.last?.sortKey, nil)
        ))
    }

    private static func removeLinks(to pageId: UUID, in parentId: UUID, _ transaction: NotesTransaction) throws {
        for block in try transaction.blocks(ofPage: parentId) where block.kind == .pageLink && block.linkedPageId == pageId {
            try transaction.deleteBlock(block.id)
        }
    }

    private static func erase(_ pages: [Page], _ transaction: NotesTransaction) throws {
        let erasedIds = Set(pages.map(\.id))
        for page in pages {
            if let parentId = page.parentId, !erasedIds.contains(parentId), try transaction.page(parentId) != nil {
                try removeLinks(to: page.id, in: parentId, transaction)
            }
        }
        for page in pages {
            try transaction.erasePage(page.id)
        }
    }
}

/// Где встаёт ссылка на подстраницу из «/» или «Преобразовать в».
public enum SubpageLinkPlacement: Sendable, Equatable {
    /// На месте блока; сам блок уходит (⌘Z возвращает его).
    case replacing(blockId: UUID)
    /// Сразу за блоком, в том же потоке и с тем же отступом.
    case after(blockId: UUID)

    var blockId: UUID {
        switch self {
        case .replacing(let id), .after(let id): id
        }
    }

    var replaces: Bool { if case .replacing = self { true } else { false } }
}
