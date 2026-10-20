import Foundation

/// Копия блоков с новыми id (research R7, R8): поддеревья по отступу, контейнеры 002 (колонки, таблицы) со своими
/// потоками, ячейки — на копиях своих столбцов. Общая для переноса в подстраницу, «Переместить в», дублирования,
/// шаблонов и восстановления версии. Только считает копии — пишет их вызывающий, в своей транзакции.
public enum BlockCopier {
    public struct Copy: Sendable {
        /// Копии в порядке чтения: блок потока, затем его контейнер с потоками.
        public var blocks: [Block] = []
        /// Исходные блоки в том же порядке.
        public var originals: [Block] = []
        /// id исходного → id копии.
        public var newIds: [UUID: UUID] = [:]
    }

    /// Скопировать `roots` — блоки одного потока по порядку (вложенные по отступу уже среди них) — на страницу `pageId`.
    /// Контейнеры берут свои потоки из `pageBlocks` (все блоки исходной страницы). Ключи потока — по порядку между
    /// `after` и `before`; глубина — относительно `indentBase` (по умолчанию — глубина первого). `marksMovedFrom` —
    /// у каждой копии в `props.movedFrom` id исходного блока.
    public static func copy(_ roots: [Block], pageBlocks: [Block], into pageId: UUID, after: FractionalSortKey? = nil,
                            before: FractionalSortKey? = nil, indentBase: Int? = nil, marksMovedFrom: Bool = false) -> Copy {
        guard let first = roots.first else { return Copy() }
        let base = indentBase ?? first.indent
        let flows = Dictionary(grouping: pageBlocks.filter { $0.containerId != nil }, by: \.containerId).mapValues { $0.sorted(by: flowOrder) }
        var result = Copy()
        func copy(_ block: Block, sortKey: FractionalSortKey, indent: Int, containerId: UUID?) {
            var props = block.props
            if marksMovedFrom { props.movedFrom = block.id }
            let copied = Block(pageId: pageId, kind: block.kind, text: block.text, indent: indent, isChecked: block.isChecked,
                               linkedPageId: block.linkedPageId, sortKey: sortKey, containerId: containerId, color: block.color, props: props)
            result.newIds[block.id] = copied.id
            result.originals.append(block)
            result.blocks.append(copied)
            for inner in flows[block.id] ?? [] {
                copy(inner, sortKey: inner.sortKey, indent: inner.indent, containerId: copied.id)
            }
        }
        var key = after
        for root in roots {
            key = .between(key, before)
            copy(root, sortKey: key!, indent: max(root.indent - base, 0), containerId: nil)
        }
        // Ячейка таблицы помнит свой столбец по id: у копии — копия столбца.
        for index in result.blocks.indices {
            if let column = result.blocks[index].props.columnId, let copied = result.newIds[column] {
                result.blocks[index].props.columnId = copied
            }
        }
        return result
    }

    /// Порядок в потоке: по ключу, при равных ключах — по id.
    public static func flowOrder(_ lhs: Block, _ rhs: Block) -> Bool {
        lhs.sortKey != rhs.sortKey ? lhs.sortKey < rhs.sortKey : lhs.id.uuidString < rhs.id.uuidString
    }
}
