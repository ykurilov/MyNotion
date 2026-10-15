import Foundation
import Observation

/// Одна живая копия страницы в памяти (research R5). Редактор правит её, а не базу;
/// автосохранение пишет накопленное (research R4). Все окна страницы получают этот же объект
/// через `OpenDocuments`, поэтому двух расходящихся копий не бывает.
@MainActor
@Observable
public final class PageDocument {
    public let pageId: UUID
    public private(set) var page: Page
    /// Блоки по порядку.
    public private(set) var blocks: [Block]
    public internal(set) var saveStatus: SaveStatus = .saved

    /// Страница и блоки так, как они записаны в базе на момент чтения или последней записи.
    @ObservationIgnored private var savedPage: Page
    @ObservationIgnored private var savedBlocks: [UUID: Block]
    @ObservationIgnored private(set) var isTitleUnsaved = false
    /// Блоки, правленные после последней записи: новые и изменённые.
    @ObservationIgnored public private(set) var unsavedBlockIds: Set<UUID> = []
    /// Блоки, которые есть в базе, но убраны из документа.
    @ObservationIgnored private(set) var removedBlockIds: Set<UUID> = []
    @ObservationIgnored private var indexById: [UUID: Int] = [:]

    /// Сообщает автосохранению о каждой правке.
    @ObservationIgnored var didEdit: (@MainActor () -> Void)?

    public init(content: PageContent) {
        pageId = content.page.id
        page = content.page
        blocks = content.blocks
        savedPage = content.page
        savedBlocks = Dictionary(uniqueKeysWithValues: content.blocks.map { ($0.id, $0) })
        reindex()
    }

    public var hasUnsavedChanges: Bool {
        isTitleUnsaved || !unsavedBlockIds.isEmpty || !removedBlockIds.isEmpty
    }

    public func block(_ id: UUID) -> Block? {
        indexById[id].map { blocks[$0] }
    }

    public func index(ofBlock id: UUID) -> Int? {
        indexById[id]
    }

    // MARK: Правки

    public func setTitle(_ title: String) {
        guard title != page.title else { return }
        page.title = title
        isTitleUnsaved = page.title != savedPage.title
        didEdit?()
    }

    public func setText(_ text: InlineText, ofBlock blockId: UUID) {
        guard let index = indexById[blockId] else { return }
        let normalized = text.normalized()
        guard blocks[index].text.normalized() != normalized else { return }
        blocks[index].text = normalized
        markEdited(blockId)
        didEdit?()
    }

    /// Заменить блоки между `after` и `before` (оба не входят; `nil` — край страницы) блоками из черновиков.
    /// Черновик с id блока из заменяемого отрезка правит этот блок; повторный, чужой или пустой id — новый блок.
    /// Неиспользованные блоки отрезка удаляются. Возвращает id блоков по порядку черновиков.
    @discardableResult
    public func replaceBlocks(after previousId: UUID?, before nextId: UUID?, with drafts: [BlockDraft]) -> [UUID] {
        let start = previousId.flatMap { indexById[$0] }.map { $0 + 1 } ?? 0
        let end = max(start, nextId.flatMap { indexById[$0] } ?? blocks.count)
        let replaced = Array(blocks[start..<end])
        let replacedIds = Set(replaced.map(\.id))

        var assigned = [UUID?](repeating: nil, count: drafts.count)
        var used: Set<UUID> = []
        for (position, draft) in drafts.enumerated() {
            if let id = draft.id, replacedIds.contains(id), used.insert(id).inserted {
                assigned[position] = id
            }
        }

        let lowerKey = start > 0 ? blocks[start - 1].sortKey : nil
        let upperKey = end < blocks.count ? blocks[end].sortKey : nil
        let replacedById = Dictionary(uniqueKeysWithValues: replaced.map { ($0.id, $0) })
        var lastKey = lowerKey
        var newBlocks: [Block] = []
        for (position, draft) in drafts.enumerated() {
            var block: Block
            if let id = assigned[position], let existing = replacedById[id] {
                block = existing
            } else {
                block = Block(pageId: pageId, sortKey: .between(lastKey, upperKey))
            }
            if let lastKey, block.sortKey <= lastKey {
                block.sortKey = .between(lastKey, upperKey)
            } else if let upperKey, block.sortKey >= upperKey {
                block.sortKey = .between(lastKey, upperKey)
            }
            draft.apply(to: &block)
            lastKey = block.sortKey
            newBlocks.append(block)
        }

        for old in replaced where !used.contains(old.id) {
            unsavedBlockIds.remove(old.id)
            if savedBlocks[old.id] != nil { removedBlockIds.insert(old.id) }
        }
        for block in newBlocks {
            removedBlockIds.remove(block.id)
            if replacedById[block.id] != block { markEdited(block.id, current: block) }
        }

        blocks.replaceSubrange(start..<end, with: newBlocks)
        reindex()
        if !newBlocks.isEmpty || !replaced.isEmpty { didEdit?() }
        return newBlocks.map(\.id)
    }

    // MARK: Запись

    /// Что записать: снимок накопленных правок.
    func unsavedChanges() -> PageDocumentChanges {
        PageDocumentChanges(
            title: isTitleUnsaved ? page.title : nil,
            upserted: unsavedBlockIds.compactMap { id in
                indexById[id].map { (current: blocks[$0], saved: savedBlocks[id]) }
            },
            removedBlockIds: removedBlockIds
        )
    }

    /// Записанное легло в базу: запомнить новые версии. Свой текст блоков в конфликте остаётся в окне.
    func didSave(_ changes: PageDocumentChanges, result: PageDocumentWriteResult) {
        if let page = result.page {
            savedPage = page
            self.page.fieldClocks = page.fieldClocks
            self.page.updatedAt = page.updatedAt
            isTitleUnsaved = self.page.title != page.title
        }
        for id in changes.removedBlockIds {
            savedBlocks[id] = nil
            removedBlockIds.remove(id)
        }
        for (id, stored) in result.blocks {
            savedBlocks[id] = stored
            unsavedBlockIds.remove(id)
            guard let index = indexById[id] else { continue }
            blocks[index].fieldClocks = stored.fieldClocks
            if !result.conflictedBlockIds.contains(id) {
                blocks[index].textBaseClock = stored.textBaseClock
            }
        }
    }

    // MARK: Внутреннее

    private func markEdited(_ id: UUID, current: Block? = nil) {
        guard let current = current ?? indexById[id].map({ blocks[$0] }) else { return }
        if let saved = savedBlocks[id], saved.hasSameContent(as: current) {
            unsavedBlockIds.remove(id)
        } else {
            unsavedBlockIds.insert(id)
        }
    }

    private func reindex() {
        indexById = Dictionary(uniqueKeysWithValues: blocks.enumerated().map { ($1.id, $0) })
    }
}

/// Желаемое содержимое блока из редактора. `id` — какой блок это был в тексте, если известно.
public struct BlockDraft: Sendable, Hashable {
    public var id: UUID?
    public var kind: BlockKind
    public var text: InlineText
    public var indent: Int
    public var isChecked: Bool
    public var linkedPageId: UUID?

    public init(id: UUID?, kind: BlockKind = .paragraph, text: InlineText = .empty, indent: Int = 0,
                isChecked: Bool = false, linkedPageId: UUID? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.indent = indent
        self.isChecked = isChecked
        self.linkedPageId = linkedPageId
    }

    func apply(to block: inout Block) {
        // Ссылка без страницы — просто абзац: иначе блок нельзя записать.
        let kind = kind == .pageLink && linkedPageId == nil ? .paragraph : kind
        block.kind = kind
        block.text = text.normalized()
        block.indent = kind.isHeading ? 0 : min(max(indent, Block.indentRange.lowerBound), Block.indentRange.upperBound)
        block.isChecked = kind == .checkbox && isChecked
        block.linkedPageId = kind == .pageLink ? linkedPageId : nil
    }
}

extension Block {
    /// Совпадает всё, что пишет автосохранение (метки часов не в счёт).
    func hasSameContent(as other: Block) -> Bool {
        kind == other.kind && text.normalized() == other.text.normalized() && indent == other.indent
            && isChecked == other.isChecked && linkedPageId == other.linkedPageId && sortKey == other.sortKey
    }
}
