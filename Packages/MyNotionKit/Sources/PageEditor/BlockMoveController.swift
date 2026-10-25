import AppKit
import NotesCore

/// Перестановка блоков мышью и клавишами окна; сами правила — `BlockStructure`.
public enum BlockMoveController {
    /// Зазор для сброса перетаскиваемого блока: 0 — над первым блоком, `count` — под последним.
    /// Блок под мышью делится пополам: выше середины — зазор над ним, ниже — под ним.
    public static func gap(forPointerY y: CGFloat, blockFrames: [ClosedRange<CGFloat>]) -> Int {
        blockFrames.firstIndex { y < ($0.lowerBound + $0.upperBound) / 2 } ?? blockFrames.count
    }

    /// Правила вложенности и перестановки живут в NotesCore (`BlockStructure`): их же используют команды `mynotion`.
    static func indenting(_ blocks: [Block], selected: Range<Int>, delta: Int) -> BlockStructure.Change? {
        BlockStructure.indenting(blocks, selected: selected, delta: delta)
    }

    static func headingIndent(_ desired: Int, under above: [(indent: Int, kind: BlockKind)]) -> Int {
        BlockStructure.headingIndent(desired, under: above)
    }

    static func headingIndent(_ desired: Int, at index: Int, in blocks: [Block]) -> Int {
        BlockStructure.headingIndent(desired, at: index, in: blocks)
    }

    static func subtreeEnd(_ blocks: [Block], of index: Int) -> Int {
        BlockStructure.subtreeEnd(blocks, of: index)
    }

    static func moving(_ blocks: [Block], selected: Range<Int>, by delta: Int) -> BlockStructure.Change? {
        BlockStructure.moving(blocks, selected: selected, by: delta)
    }

    static func movedGroup(_ blocks: [Block], selected: Range<Int>) -> Range<Int> {
        BlockStructure.movedGroup(blocks, selected: selected)
    }

    static func moving(_ blocks: [Block], group: Range<Int>, toGap gap: Int) -> BlockStructure.Change? {
        BlockStructure.moving(blocks, group: group, toGap: gap)
    }
}

extension PageTextView {
    // MARK: Вложенность и перестановка

    func indentSelectedBlocks(by delta: Int) {
        commitEdits()
        guard let selected = selectedBlockRange(),
              let change = BlockMoveController.indenting(document.blocks, selected: selected, delta: delta) else { return }
        changeBlocks(change.range, to: change.drafts, actionName: delta > 0 ? "Вложить" : "Вынуть")
    }

    func moveSelectedBlocks(by delta: Int) {
        commitEdits()
        // Свёрнутый заголовок последним в выделении едет со своим разделом.
        guard let selected = selectedBlockRange().map({ $0.lowerBound..<max($0.upperBound, movedGroupEnd(ofBlockAt: $0.upperBound - 1)) }),
              let change = BlockMoveController.moving(document.blocks, selected: selected, by: delta) else { return }
        let moved = Set(document.blocks[BlockMoveController.movedGroup(document.blocks, selected: selected)].map(\.id))
        changeBlocks(change.range, to: change.drafts, moved: moved, actionName: "Переставить блок")
    }

    /// Перетащить блок за «⋮⋮» вместе с вложенными (свёрнутый заголовок — с разделом) в зазор `gap` между блоками
    /// (0 — в начало страницы).
    public func moveBlock(_ id: UUID, toGap gap: Int) {
        commitEdits()
        guard let index = document.index(ofBlock: id) else { return }
        let group = index..<movedGroupEnd(ofBlockAt: index)
        guard let change = BlockMoveController.moving(document.blocks, group: group, toGap: gap) else { return }
        let moved = Set(document.blocks[group].map(\.id))
        changeBlocks(change.range, to: change.drafts, moved: moved, actionName: "Переставить блок")
    }
}
