import Foundation

/// «Переместить в» для блоков (research R8, contracts/page-operations.md, «Перенос блоков»): выделенные блоки
/// с поддеревьями и контейнерами 002 — в конец потока страницы-цели копиями `BlockCopier` с `movedFrom`, исходные
/// удалены; подстраницы, чьи ссылки переехали, — под цель. Синхронизация не знает смены страницы у блока: копия
/// с удалением — тот же путь, что у «Преобразовать в → Страница». Одна транзакция, одна запись отмены.
extension PageTreeOperations {
    /// Что сделал перенос: для отмены и повтора.
    private struct BlocksMove {
        /// Исходные блоки с содержимым контейнеров, как лежали (сначала контейнер, потом его потоки).
        var originals: [Block]
        var copies: [Block]
        /// Пустой абзац, если на исходной странице не осталось блоков.
        var placeholder: Block?
        var copiedIds: [UUID: UUID]
        var reparented: [(pageId: UUID, from: (parentId: UUID?, sortKey: FractionalSortKey), to: (parentId: UUID?, sortKey: FractionalSortKey))]
    }

    /// Перенести блоки `blockIds` со страницы `sourcePageId` в конец `targetPageId`. Вложенные под выделенным блоком
    /// едут с ним, даже если не выделены; глубина первого — 0, остальные — относительно него.
    public func moveBlocks(_ blockIds: [UUID], from sourcePageId: UUID, to targetPageId: UUID) throws {
        guard sourcePageId != targetPageId else { throw NotesStoreError.invalidPage("блоки уже на этой странице") }
        let move = try perform { transaction -> BlocksMove in
            guard try transaction.page(targetPageId) != nil else { throw NotesStoreError.pageNotFound(targetPageId) }
            let blocks = try transaction.blocks(ofPage: sourcePageId)
            let roots = Self.movedRoots(blockIds, in: blocks)
            guard !roots.isEmpty else { throw NotesStoreError.blockNotFound(blockIds.first ?? UUID()) }
            let last = try transaction.blocks(ofPage: targetPageId).filter { $0.containerId == nil }.map(\.sortKey).max()
            let copy = BlockCopier.copy(roots, pageBlocks: blocks, into: targetPageId, after: last, marksMovedFrom: true)

            for original in copy.originals.reversed() { try transaction.deleteBlock(original.id) }
            var placeholder: Block?
            if try transaction.blocks(ofPage: sourcePageId).isEmpty {
                placeholder = try transaction.insertBlock(Block(pageId: sourcePageId, sortKey: .between(nil, nil)))
            }
            for block in copy.blocks { try transaction.insertBlock(block) }

            var move = BlocksMove(originals: copy.originals, copies: copy.blocks, placeholder: placeholder, copiedIds: copy.newIds,
                                  reparented: [])
            var pageKey = try transaction.allPages().filter { $0.parentId == targetPageId && $0.trashedAt == nil }.map(\.sortKey).max()
            for copied in copy.blocks where copied.kind == .pageLink {
                guard let linked = copied.linkedPageId, var subpage = try transaction.page(linked), subpage.parentId == sourcePageId else { continue }
                pageKey = .between(pageKey, nil)
                move.reparented.append((linked, (subpage.parentId, subpage.sortKey), (targetPageId, pageKey!)))
                (subpage.parentId, subpage.sortKey) = (targetPageId, pageKey!)
                try transaction.updatePage(subpage)
            }
            return move
        }
        try moveCollapsed(move.copiedIds)
        registerUndo("Перенос блоков") { try $0.returnBlocks(move) }
    }

    /// Отмена: исходные блоки с прежними id на прежних местах, копий нет, подстраницы — у прежнего родителя.
    private func returnBlocks(_ move: BlocksMove) throws {
        try perform { transaction in
            for moved in move.reparented {
                guard var page = try transaction.page(moved.pageId) else { continue }
                (page.parentId, page.sortKey) = moved.from
                try transaction.updatePage(page)
            }
            for copy in move.copies.reversed() where try transaction.block(copy.id) != nil { try transaction.deleteBlock(copy.id) }
            for original in move.originals where try transaction.block(original.id) == nil { try transaction.insertBlock(original) }
            if let placeholder = move.placeholder, try transaction.block(placeholder.id) != nil {
                try transaction.deleteBlock(placeholder.id)
            }
        }
        try moveCollapsed(Dictionary(uniqueKeysWithValues: move.copiedIds.map { ($1, $0) }))
        registerUndo("Перенос блоков") { try $0.repeatMove(move) }
    }

    /// Повтор: те же копии с теми же id снова у цели.
    private func repeatMove(_ move: BlocksMove) throws {
        try perform { transaction in
            for original in move.originals.reversed() where try transaction.block(original.id) != nil {
                try transaction.deleteBlock(original.id)
            }
            if let placeholder = move.placeholder, try transaction.block(placeholder.id) == nil {
                try transaction.insertBlock(placeholder)
            }
            for copy in move.copies where try transaction.block(copy.id) == nil { try transaction.insertBlock(copy) }
            for moved in move.reparented {
                guard var page = try transaction.page(moved.pageId) else { continue }
                (page.parentId, page.sortKey) = moved.to
                try transaction.updatePage(page)
            }
        }
        try moveCollapsed(move.copiedIds)
        registerUndo("Перенос блоков") { try $0.returnBlocks(move) }
    }

    /// Выделенные блоки в порядке страницы, каждый — с поддеревом своего потока (следующие с отступом больше).
    /// Блок внутри уже взятого поддерева или контейнера второй раз не берётся.
    private static func movedRoots(_ blockIds: [UUID], in blocks: [Block]) -> [Block] {
        let selected = Set(blockIds)
        let flows = Dictionary(grouping: blocks, by: \.containerId).mapValues { $0.sorted(by: BlockCopier.flowOrder) }
        var taken: Set<UUID> = []
        func take(_ block: Block) {
            taken.insert(block.id)
            for inner in flows[block.id] ?? [] { take(inner) }
        }
        var roots: [Block] = []
        for block in documentOrder(blocks) where selected.contains(block.id) && !taken.contains(block.id) {
            let flow = flows[block.containerId] ?? []
            guard let index = flow.firstIndex(where: { $0.id == block.id }) else { continue }
            let subtree = [block] + flow[(index + 1)...].prefix { $0.indent > block.indent }
            subtree.forEach(take)
            roots += subtree
        }
        return roots
    }
}
