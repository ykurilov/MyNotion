import Foundation

/// Какой сделать страницу восстановлением версии: поля и блоки всех потоков (снимок версии, research R11).
public struct PageRestoreTarget: Sendable, Hashable {
    public var title: String
    public var icon: String?
    public var cover: PageCover?
    public var isFullWidth: Bool
    public var isSmallText: Bool
    public var blocks: [Block]

    public init(title: String, icon: String?, cover: PageCover?, isFullWidth: Bool, isSmallText: Bool, blocks: [Block]) {
        self.title = title
        self.icon = icon
        self.cover = cover
        self.isFullWidth = isFullWidth
        self.isSmallText = isSmallText
        self.blocks = blocks
    }

    init(page: Page, blocks: [Block]) {
        self.init(title: page.title, icon: page.icon, cover: page.cover, isFullWidth: page.isFullWidth, isSmallText: page.isSmallText,
                  blocks: blocks)
    }
}

/// Восстановление версии (contracts/page-operations.md, «История версий»): одна транзакция и одна запись отмены.
/// Поля страницы — как в версии; блоки — правятся под версию, лишние удаляются, удалённые с тех пор возвращаются с прежними
/// id; копии блоков версии, унесённые «Переместить в» на другие страницы (`props.movedFrom`), удаляются, а подстраницы
/// их ссылок возвращаются под страницу. Уходит на другие Mac обычными правками.
extension PageTreeOperations {
    public func restoreVersion(of pageId: UUID, to target: PageRestoreTarget) throws {
        let inverse = try perform { transaction in
            try Self.apply(RestoreStep(pageId: pageId, target: target, returnsMovedBlocks: true), transaction)
        }
        registerUndo(Self.restoreActionName) { try $0.redoRestore(inverse) }
    }

    static let restoreActionName = "Восстановление версии"

    /// Отмена и повтор: обратный шаг — тот же путь, его обратный — снова в стопку.
    private func redoRestore(_ step: RestoreStep) throws {
        let inverse = try perform { try Self.apply(step, $0) }
        registerUndo(Self.restoreActionName) { try $0.redoRestore(inverse) }
    }

    /// Шаг восстановления; `apply` возвращает обратный шаг.
    struct RestoreStep: Sendable {
        let pageId: UUID
        var target: PageRestoreTarget
        /// Искать копии блоков версии на других страницах (`movedFrom`) и удалять их.
        var returnsMovedBlocks = false
        /// Блоки других страниц: вернуть (отмена удаления копий) и удалить (повтор).
        var insertsElsewhere: [Block] = []
        var deletesElsewhere: [UUID] = []
        /// Подстраницы: новое место (родитель и ключ).
        var placements: [(pageId: UUID, parentId: UUID?, sortKey: FractionalSortKey)] = []
    }

    private static func apply(_ step: RestoreStep, _ transaction: NotesTransaction) throws -> RestoreStep {
        let pageId = step.pageId
        guard var page = try transaction.page(pageId) else { throw NotesStoreError.pageNotFound(pageId) }
        let current = try transaction.blocks(ofPage: pageId)
        var inverse = RestoreStep(pageId: pageId, target: PageRestoreTarget(page: page, blocks: current))
        let allPages = Dictionary(uniqueKeysWithValues: try transaction.allPages().map { ($0.id, $0) })

        // Копии блоков версии на других страницах и подстраницы их ссылок (они вернутся сюда вместе со ссылкой).
        var removedElsewhere: [Block] = []
        var returningSubpages: Set<UUID> = []
        if step.returnsMovedBlocks {
            let versionIds = Set(step.target.blocks.map(\.id))
            for copy in try transaction.movedBlockCopies(of: versionIds, outsidePage: pageId) {
                removedElsewhere.append(copy)
                if let linked = copy.linkedPageId, allPages[linked]?.parentId == copy.pageId { returningSubpages.insert(linked) }
            }
        }
        for id in step.deletesElsewhere {
            if let block = try transaction.block(id) { removedElsewhere.append(block) }
        }
        for block in removedElsewhere.reversed() where try transaction.block(block.id) != nil {
            try transaction.deleteBlock(block.id)
        }
        inverse.insertsElsewhere = removedElsewhere
        inverse.deletesElsewhere = step.insertsElsewhere.map(\.id)

        // Подстраницы: возвращённые со ссылкой — под эту страницу, остальные места — как просит шаг.
        var placements = step.placements
        let lastChildKey = allPages.values.filter { $0.parentId == pageId }.map(\.sortKey).max()
        var key = lastChildKey
        for subpageId in returningSubpages.sorted(by: { $0.uuidString < $1.uuidString }) {
            key = .between(key, nil)
            placements.append((subpageId, pageId, key!))
        }
        var parentAfter = allPages.mapValues(\.parentId)
        for placement in placements {
            guard var subpage = try transaction.page(placement.pageId) else { continue }
            inverse.placements.append((subpage.id, subpage.parentId, subpage.sortKey))
            (subpage.parentId, subpage.sortKey) = (placement.parentId, placement.sortKey)
            parentAfter[subpage.id] = placement.parentId
            try transaction.updatePage(subpage)
        }
        /// Живая подстраница этой страницы после перестановок.
        func isLiveChild(_ id: UUID) -> Bool {
            (allPages[id].map { $0.trashedAt == nil } ?? false) && (parentAfter[id] ?? nil) == pageId
        }

        // Поля страницы.
        page.title = step.target.title
        page.icon = step.target.icon
        page.cover = step.target.cover
        page.isFullWidth = step.target.isFullWidth
        page.isSmallText = step.target.isSmallText
        try transaction.updatePage(page)

        // Блоки страницы. Ссылка на подстраницу, живущую сейчас в другом месте дерева, не возвращается: подстраница —
        // там, где её положили. Ссылки на живые подстраницы этой страницы, которых нет в версии, остаются — иначе
        // подстраница осталась бы в дереве без ссылки.
        let targetBlocks = step.target.blocks.filter { block in
            guard let linked = block.linkedPageId, let subpage = allPages[linked], subpage.trashedAt == nil else { return true }
            return isLiveChild(linked)
        }
        let targetIds = Set(targetBlocks.map(\.id))
        let linkedInTarget = Set(targetBlocks.compactMap(\.linkedPageId))
        for block in current.reversed() where !targetIds.contains(block.id) {
            if let linked = block.linkedPageId, !linkedInTarget.contains(linked), isLiveChild(linked) { continue }
            try transaction.deleteBlock(block.id)
        }
        let currentById = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        for block in targetBlocks {
            if let stored = currentById[block.id] {
                var updated = stored
                updated.kind = block.kind
                updated.text = block.text
                updated.indent = block.indent
                updated.isChecked = block.isChecked
                updated.linkedPageId = block.linkedPageId
                updated.sortKey = block.sortKey
                updated.containerId = block.containerId
                updated.color = block.color
                updated.props = block.props
                try transaction.updateBlock(updated)
            } else if try transaction.block(block.id) == nil {
                // Удалённый с тех пор блок — с прежним id; пометка «удалён» снимается новой меткой часов (как ⌘Z удаления 002).
                try transaction.insertBlock(block)
            }
        }

        for block in step.insertsElsewhere where try transaction.block(block.id) == nil {
            try transaction.insertBlock(block)
        }
        return inverse
    }
}

extension NotesTransaction {
    /// Живые блоки других страниц, перенесённые «Переместить в» из блоков `blockIds` (`props.movedFrom`).
    func movedBlockCopies(of blockIds: Set<UUID>, outsidePage pageId: UUID) throws -> [Block] {
        guard !blockIds.isEmpty else { return [] }
        return try blocks(movedFrom: blockIds, outsidePage: pageId)
    }
}
