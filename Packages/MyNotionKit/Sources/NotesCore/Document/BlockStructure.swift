import Foundation

/// Правила вложенности и перестановки блоков (FR-008, FR-011): что получится из блоков, без текста и окна.
/// Ими пользуются и окно (Tab, ⌥⇧↑↓, перетаскивание «⋮⋮»), и команды `mynotion block …` — правила одни.
public enum BlockStructure {
    /// Отрезок блоков страницы и их новые черновики вместо него.
    public typealias Change = (range: Range<Int>, drafts: [BlockDraft])

    /// Вложенность после Tab (`delta` = 1) или ⇧Tab (`delta` = −1) для выделенных блоков.
    /// Правило глубины (data-model.md, «Block»): блок вкладывается не глубже соседа сверху + 1, если сосед — пункт,
    /// чекбокс, переключатель, выноска или цитата, иначе не глубже соседа; заголовок — только внутрь переключателя,
    /// выноски, цитаты; всё — в 0…8. Вложенные под последним выделенным блоком сдвигаются вместе с ним.
    /// Возвращает отрезок блоков с новыми черновиками или `nil`, если ничего не меняется.
    public static func indenting(_ blocks: [Block], selected: Range<Int>, delta: Int) -> Change? {
        guard !selected.isEmpty else { return nil }
        var drafts: [BlockDraft] = []
        // Блоки выше уже с новой вложенностью: по ним ищется предок заголовка.
        var above: [(indent: Int, kind: BlockKind)] = blocks[..<selected.lowerBound].map { ($0.indent, $0.kind) }
        for block in blocks[selected] {
            var draft = BlockDraft(block)
            let ceiling = above.last.map { min($0.indent + ($0.kind.canHaveChildren ? 1 : 0), Block.indentRange.upperBound) } ?? 0
            var indent = delta > 0
                ? max(block.indent, min(block.indent + 1, ceiling))
                : max(block.indent - 1, Block.indentRange.lowerBound)
            if block.kind.isHeading {
                let legal = headingIndent(indent, under: above)
                indent = delta > 0 && legal < indent ? block.indent : legal
            }
            draft.indent = indent
            above.append((indent, block.kind))
            drafts.append(draft)
        }

        let last = blocks[selected.upperBound - 1]
        let shift = drafts[drafts.count - 1].indent - last.indent
        var end = selected.upperBound
        while end < blocks.count, blocks[end].indent > last.indent {
            var child = BlockDraft(blocks[end])
            child.indent = max(min(child.indent + shift, Block.indentRange.upperBound), Block.indentRange.lowerBound)
            drafts.append(child)
            end += 1
        }

        let range = selected.lowerBound..<end
        guard zip(blocks[range], drafts).contains(where: { $0.indent != $1.indent }) else { return nil }
        return (range, drafts)
    }

    /// Самая глубокая допустимая вложенность заголовка не глубже `desired` под блоками `above` (по порядку страницы):
    /// его предок на уровень выше должен быть переключателем, выноской или цитатой.
    public static func headingIndent(_ desired: Int, under above: [(indent: Int, kind: BlockKind)]) -> Int {
        var indent = desired
        while indent > 0 {
            guard let parent = above.last(where: { $0.indent < indent }) else { return 0 }
            if parent.indent == indent - 1, parent.kind.allowsHeadingChildren { return indent }
            indent -= 1
        }
        return 0
    }

    /// Вложенность заголовка на месте блока `index` (смена типа на заголовок): сколько можно оставить из нынешней.
    public static func headingIndent(_ desired: Int, at index: Int, in blocks: [Block]) -> Int {
        headingIndent(desired, under: blocks[..<index].map { ($0.indent, $0.kind) })
    }

    /// Конец вложенных пунктов блока `index`: следующие блоки глубже него едут вместе с ним.
    public static func subtreeEnd(_ blocks: [Block], of index: Int) -> Int {
        var end = index + 1
        while end < blocks.count, blocks[end].indent > blocks[index].indent { end += 1 }
        return end
    }

    /// Перестановка выделенных блоков вместе с вложенными на одно место выше (`delta` = −1) или ниже (`delta` = 1),
    /// как в Notion: сосед переступается целиком, со своими вложенными.
    public static func moving(_ blocks: [Block], selected: Range<Int>, by delta: Int) -> Change? {
        guard !selected.isEmpty else { return nil }
        let group = selected.lowerBound..<subtreeEnd(blocks, of: selected.upperBound - 1)
        let groupIndent = blocks[group.lowerBound].indent
        if delta < 0 {
            // Сосед выше — ближайший блок не глубже группы; всё между ним и группой — его вложенные.
            guard let above = blocks[..<group.lowerBound].lastIndex(where: { $0.indent <= groupIndent }) else { return nil }
            let range = above..<group.upperBound
            return (range, blocks[group].map(BlockDraft.init) + blocks[above..<group.lowerBound].map(BlockDraft.init))
        }
        guard group.upperBound < blocks.count else { return nil }
        let below = group.upperBound..<subtreeEnd(blocks, of: group.upperBound)
        return (group.lowerBound..<below.upperBound, blocks[below].map(BlockDraft.init) + blocks[group].map(BlockDraft.init))
    }

    /// Блоки, которые едут при перестановке выделенных: выделенные и вложенные под последним.
    public static func movedGroup(_ blocks: [Block], selected: Range<Int>) -> Range<Int> {
        selected.isEmpty ? selected : selected.lowerBound..<subtreeEnd(blocks, of: selected.upperBound - 1)
    }

    /// Перенос блока `index` вместе с вложенными в зазор `gap` (0…count). В свои же вложенные блок не переносится.
    public static func moving(_ blocks: [Block], blockAt index: Int, toGap gap: Int) -> Change? {
        guard blocks.indices.contains(index) else { return nil }
        return moving(blocks, group: index..<subtreeEnd(blocks, of: index), toGap: gap)
    }

    /// Перенос блоков `group` (блок с тем, что едет вместе с ним) в зазор `gap` (0…count).
    public static func moving(_ blocks: [Block], group: Range<Int>, toGap gap: Int) -> Change? {
        guard !group.isEmpty, group.upperBound <= blocks.count, (0...blocks.count).contains(gap) else { return nil }
        let index = group.lowerBound
        guard gap < group.lowerBound || gap > group.upperBound else { return nil }
        let moved = blocks[group].map(BlockDraft.init)
        if gap < index {
            return (gap..<group.upperBound, moved + blocks[gap..<index].map(BlockDraft.init))
        }
        return (index..<gap, blocks[group.upperBound..<gap].map(BlockDraft.init) + moved)
    }
}
