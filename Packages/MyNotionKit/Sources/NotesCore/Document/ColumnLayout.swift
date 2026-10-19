import Foundation

/// Колонки (data-model.md, «Правила»; research R3): `columnList` в потоке, в нём 2–5 колонок `column`,
/// у каждой — свой поток блоков. Правки собирают и разбирают колонки одной правкой `BlockChanges`:
/// перенос меняет у блока только место (`containerId` + `sortKey`), id остаётся.
public enum ColumnLayout {
    public static let maximumColumns = 5
    /// Доля ширины одной колонки.
    public static let ratioRange: ClosedRange<Double> = 0.1...0.9

    /// Доли ширины колонок для показа: свои у колонок, без своей — поровну из остатка; сумма 1.
    public static func ratios(of columns: [Block]) -> [Double] {
        guard !columns.isEmpty else { return [] }
        let own = columns.map { $0.props.widthRatio.map { min(max($0, ratioRange.lowerBound), ratioRange.upperBound) } }
        let known = own.compactMap { $0 }
        let missing = own.count - known.count
        let share = missing > 0 ? max(ratioRange.lowerBound, (1 - known.reduce(0, +)) / Double(missing)) : 0
        let raw = own.map { $0 ?? share }
        let total = raw.reduce(0, +)
        return raw.map { (($0 / total) * 1_000_000).rounded() / 1_000_000 }
    }
}

@MainActor
extension PageDocument {
    /// Блоки `moved` (корень и его поддерево из одного потока, по порядку) — к правому краю блока `targetId`:
    /// у блока вне колонок на его месте встают колонки (он слева, перенесённые справа); у блока в колонке —
    /// новая колонка справа от его колонки. `nil` — так поставить нельзя (сам с собой, внутрь себя, шестая колонка).
    public func changesPlacing(_ moved: [UUID], besideRightOf targetId: UUID) -> BlockChanges? {
        guard !moved.isEmpty, let target = block(targetId), !moved.contains(targetId),
              !containerChain(of: target).contains(where: moved.contains) else { return nil }
        var draft = PlacementDraft(document: self)

        if let columnId = target.containerId, let column = block(columnId), column.kind == .column,
           let listId = column.containerId, let list = block(listId), list.kind == .columnList {
            let columns = flow(listId)
            guard let position = columns.firstIndex(where: { $0.id == columnId }) else { return nil }
            let newColumn = Block(pageId: pageId, kind: .column,
                                  sortKey: .between(column.sortKey, columns[safe: position + 1]?.sortKey), containerId: listId)
            draft.put(newColumn)
            draft.move(moved, to: newColumn.id, after: nil, before: nil, rootIndent: 0)
            draft.removeEmptiedColumns()
            guard draft.flow(listId).count <= ColumnLayout.maximumColumns else { return nil }
            draft.resetRatios(of: listId)
            return draft.changes
        }

        // Цель вне колонок: её место занимают колонки, она с поддеревом — в левой колонке.
        let targetFlow = target.containerId.map(flow) ?? blocks
        let subtree = Self.subtree(of: target, in: targetFlow).filter { !moved.contains($0.id) }
        let list = Block(pageId: pageId, kind: .columnList, indent: target.indent, sortKey: target.sortKey, containerId: target.containerId)
        let left = Block(pageId: pageId, kind: .column, sortKey: .between(nil, nil), containerId: list.id)
        let right = Block(pageId: pageId, kind: .column, sortKey: .between(left.sortKey, nil), containerId: list.id)
        draft.put(list)
        draft.put(left)
        draft.put(right)
        draft.move(subtree.map(\.id), to: left.id, after: nil, before: nil, rootIndent: 0)
        draft.move(moved, to: right.id, after: nil, before: nil, rootIndent: 0)
        draft.removeEmptiedColumns()
        return draft.changes
    }

    /// Блоки `moved` (по порядку) — в поток `containerId` между `previousId` и `nextId` (`nil` — край потока;
    /// оба `nil` — в конец). Корень встаёт на глубину `rootIndent`, поддерево — с прежней разницей. Опустевшая колонка
    /// исчезает в той же правке; осталась одна — колонки распадаются, её блоки встают на место колонок.
    public func changesMoving(_ moved: [UUID], to containerId: UUID?, after previousId: UUID?, before nextId: UUID?,
                              rootIndent: Int = 0) -> BlockChanges {
        var draft = PlacementDraft(document: self)
        draft.move(moved, to: containerId, after: previousId, before: nextId, rootIndent: rootIndent)
        draft.removeEmptiedColumns()
        return draft.changes
    }

    /// Доли ширины колонок (граница колонок протянута): каждая 10–90 %, сумма 1.
    public func changesSettingColumnRatios(_ ratios: [Double], ofColumnList listId: UUID) -> BlockChanges? {
        let columns = flow(listId)
        guard columns.count == ratios.count, !columns.isEmpty else { return nil }
        let clamped = ratios.map { min(max($0, ColumnLayout.ratioRange.lowerBound), ColumnLayout.ratioRange.upperBound) }
        let total = clamped.reduce(0, +)
        let upserts = zip(columns, clamped).compactMap { column, ratio -> Block? in
            var column = column
            let value = ((ratio / total) * 10_000).rounded() / 10_000
            guard column.props.widthRatio != value else { return nil }
            column.props.widthRatio = value
            return column
        }
        return BlockChanges(upserts: upserts)
    }

    /// Блок и следующие за ним блоки глубже него в его потоке.
    static func subtree(of root: Block, in flow: [Block]) -> [Block] {
        guard let start = flow.firstIndex(where: { $0.id == root.id }) else { return [root] }
        var end = start + 1
        while end < flow.count, flow[end].indent > root.indent { end += 1 }
        return Array(flow[start..<end])
    }

    /// Контейнеры блока вверх до потока страницы.
    public func containerChain(of block: Block) -> [UUID] {
        var chain: [UUID] = []
        var current = block.containerId
        while let id = current, !chain.contains(id) {
            chain.append(id)
            current = self.block(id)?.containerId
        }
        return chain
    }
}

/// Правка мест, собираемая по шагам поверх документа: потоки видны уже с ней.
@MainActor
private struct PlacementDraft {
    let document: PageDocument
    private var placed: [UUID: Block] = [:]
    private var removed: [UUID] = []
    /// Колонки, из которых уносили блоки.
    private var sources: Set<UUID> = []

    init(document: PageDocument) {
        self.document = document
    }

    var changes: BlockChanges {
        BlockChanges(upserts: placed.values.filter { !removed.contains($0.id) }.sorted { $0.id.uuidString < $1.id.uuidString },
                     removals: removed)
    }

    func current(_ id: UUID) -> Block? {
        removed.contains(id) ? nil : placed[id] ?? document.block(id)
    }

    mutating func put(_ block: Block) {
        placed[block.id] = block
    }

    /// Поток контейнера с уже сделанными шагами, по порядку ключей.
    func flow(_ containerId: UUID?) -> [Block] {
        let base = (containerId.map(document.flow) ?? document.blocks).compactMap { current($0.id) }.filter { block in
            // Сирота в потоке страницы стоит со своим контейнером.
            containerId == nil ? placed[block.id] == nil || block.containerId == nil : block.containerId == containerId
        }
        let baseIds = Set(base.map(\.id))
        let arrived = placed.values.filter { $0.containerId == containerId && !baseIds.contains($0.id) && !removed.contains($0.id) }
        guard !arrived.isEmpty || base.contains(where: { placed[$0.id] != nil }) else { return base }
        return (base + arrived).sorted { $0.sortKey != $1.sortKey ? $0.sortKey < $1.sortKey : $0.id.uuidString < $1.id.uuidString }
    }

    mutating func move(_ ids: [UUID], to containerId: UUID?, after previousId: UUID?, before nextId: UUID?, rootIndent: Int) {
        let blocks = ids.compactMap(current)
        guard let root = blocks.first else { return }
        let target = flow(containerId).filter { !ids.contains($0.id) }
        var lower: FractionalSortKey?
        var upper: FractionalSortKey?
        if let previousId {
            lower = target.first { $0.id == previousId }?.sortKey
            let position = target.firstIndex { $0.id == previousId }
            upper = nextId.flatMap { id in target.first { $0.id == id }?.sortKey } ?? position.flatMap { target[safe: $0 + 1]?.sortKey }
        } else if let nextId {
            upper = target.first { $0.id == nextId }?.sortKey
        } else {
            lower = target.last?.sortKey
        }
        let delta = rootIndent - root.indent
        for var block in blocks {
            if let containerId = block.containerId, document.block(containerId)?.kind == .column { sources.insert(containerId) }
            let key = FractionalSortKey.between(lower, upper)
            block.containerId = containerId
            block.sortKey = key
            block.indent = min(max(block.indent + delta, Block.indentRange.lowerBound), Block.indentRange.upperBound)
            lower = key
            placed[block.id] = block
        }
    }

    /// Опустевшие колонки — долой; список колонок с одной колонкой распадается, без колонок — удаляется.
    mutating func removeEmptiedColumns() {
        var lists: Set<UUID> = []
        for columnId in sources where flow(columnId).isEmpty {
            guard let column = current(columnId) else { continue }
            removed.append(columnId)
            if let listId = column.containerId { lists.insert(listId) }
        }
        for listId in lists {
            guard let list = current(listId) else { continue }
            let columns = flow(listId)
            if columns.count > 1 {
                resetRatios(of: listId)
            } else {
                // Колонки распадаются: блоки последней колонки — на место списка, в его поток.
                let neighbours = flow(list.containerId)
                let position = neighbours.firstIndex { $0.id == listId }
                let previous = position.flatMap { $0 > 0 ? neighbours[$0 - 1].id : nil }
                let next = position.flatMap { neighbours[safe: $0 + 1]?.id }
                if let last = columns.first {
                    let contents = flow(last.id)
                    removed.append(last.id)
                    move(contents.map(\.id), to: list.containerId, after: previous, before: next ?? (previous == nil ? listId : nil),
                         rootIndent: list.indent)
                    // Ключи встали до места списка: список удаляется следом.
                }
                removed.append(listId)
            }
        }
    }

    /// Колонок стало другое число: ширины поровну.
    mutating func resetRatios(of listId: UUID) {
        for var column in flow(listId) where column.props.widthRatio != nil {
            column.props.widthRatio = nil
            placed[column.id] = column
        }
    }
}
