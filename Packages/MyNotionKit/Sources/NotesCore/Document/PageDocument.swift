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
    /// Поток страницы по порядку: блоки без контейнера и сироты — блоки, чьего контейнера в документе нет
    /// (data-model.md, «Потоки»). Блоки колонок и таблиц — в `flow(_:)`.
    public private(set) var blocks: [Block]
    public internal(set) var saveStatus: SaveStatus = .saved
    /// Конфликты текста в блоках страницы, ждущие выбора Юрия («Две версии», FR-021).
    public internal(set) var pendingConflicts: [Conflict] = []

    /// Страница и блоки так, как они записаны в базе на момент чтения или последней записи.
    @ObservationIgnored private var savedPage: Page
    @ObservationIgnored private var savedBlocks: [UUID: Block]
    @ObservationIgnored private(set) var isTitleUnsaved = false
    /// Блоки, правленные после последней записи: новые и изменённые.
    @ObservationIgnored public private(set) var unsavedBlockIds: Set<UUID> = []
    /// Блоки, которые есть в базе, но убраны из документа.
    @ObservationIgnored private(set) var removedBlockIds: Set<UUID> = []
    /// Место в потоке страницы.
    @ObservationIgnored private var indexById: [UUID: Int] = [:]
    /// Все блоки страницы, всех потоков.
    @ObservationIgnored private var byId: [UUID: Block] = [:]
    /// Потоки контейнеров: id блоков по `sortKey`.
    @ObservationIgnored private var flowOrder: [UUID: [UUID]] = [:]
    /// Удалённые контейнеры и их контейнер — для места сирот.
    @ObservationIgnored private var removedContainers: [UUID: UUID?] = [:]

    /// Сообщает автосохранению о каждой правке.
    @ObservationIgnored var didEdit: (@MainActor () -> Void)?

    public init(content: PageContent, conflicts: [Conflict] = []) {
        pendingConflicts = conflicts
        pageId = content.page.id
        page = content.page
        blocks = []
        savedPage = content.page
        savedBlocks = Dictionary(uniqueKeysWithValues: content.blocks.map { ($0.id, $0) })
        byId = savedBlocks
        removedContainers = content.removedContainers
        rebuildFlows()
    }

    public var hasUnsavedChanges: Bool {
        isTitleUnsaved || !unsavedBlockIds.isEmpty || !removedBlockIds.isEmpty
    }

    /// Блок любого потока.
    public func block(_ id: UUID) -> Block? {
        byId[id]
    }

    /// Место блока в потоке страницы; у блоков колонок и таблиц — `nil`.
    public func index(ofBlock id: UUID) -> Int? {
        indexById[id]
    }

    /// Блоки контейнера по порядку: колонки `columnList`, блоки колонки, строки и столбцы таблицы, ячейки строки.
    public func flow(_ containerId: UUID) -> [Block] {
        flowOrder[containerId]?.compactMap { byId[$0] } ?? []
    }

    /// Блок стоит в потоке страницы, хотя его контейнер удалён или ещё не пришёл. Его запись не меняется.
    public func isOrphan(_ id: UUID) -> Bool {
        indexById[id] != nil && byId[id]?.containerId != nil
    }

    // MARK: Правки

    /// `origin` — кто правит (редактор окна): другие окна этой страницы получат `didApplyLocalEdits`.
    public func setTitle(_ title: String, origin: AnyObject? = nil) {
        guard title != page.title else { return }
        page.title = title
        isTitleUnsaved = page.title != savedPage.title
        didEdit?()
        var change = ExternalChange()
        change.titleChanged = true
        postLocalEdits(change, origin: origin)
    }

    /// Иконку сменили в обход документа (`PageTreeOperations.setIcon`): подставить записанную, не трогая
    /// несохранённое. Автосохранение пишет только название, поэтому иконку не затрёт.
    public func adoptIcon(of stored: Page) {
        page.icon = stored.icon
        page.fieldClocks.icon = stored.fieldClocks.icon
        savedPage.icon = stored.icon
        savedPage.fieldClocks.icon = stored.fieldClocks.icon
    }

    public func setText(_ text: InlineText, ofBlock blockId: UUID) {
        guard var block = byId[blockId] else { return }
        let normalized = text.normalized()
        guard block.text.normalized() != normalized else { return }
        block.text = normalized
        put(block)
        markEdited(blockId)
        didEdit?()
    }

    /// Заменить блоки между `after` и `before` (оба не входят; `nil` — край потока) блоками из черновиков.
    /// `containerId` — поток: `nil` — поток страницы, иначе — контейнер (колонка, строка таблицы…).
    /// Черновик с id блока из заменяемого отрезка правит этот блок; повторный, чужой или пустой id — новый блок.
    /// Неиспользованные блоки отрезка удаляются, у контейнера — вместе со всем, что внутри. Возвращает id блоков
    /// по порядку черновиков. Ключи порядка меняются у как можно меньшего числа блоков; `movedBlockIds` — блоки,
    /// которые переставили, новый ключ получают именно они, а не соседи. Сирота на месте сохраняет свою запись;
    /// переставленная сирота встаёт в поток.
    @discardableResult
    public func replaceBlocks(in containerId: UUID? = nil, after previousId: UUID?, before nextId: UUID?, with drafts: [BlockDraft],
                              movedBlockIds: Set<UUID> = [], origin: AnyObject? = nil) -> [UUID] {
        let flow = containerId.map(flow) ?? blocks
        let positions = containerId == nil ? indexById : Dictionary(uniqueKeysWithValues: flow.enumerated().map { ($1.id, $0) })
        let start = previousId.flatMap { positions[$0] }.map { $0 + 1 } ?? 0
        let end = max(start, nextId.flatMap { positions[$0] } ?? flow.count)
        let replaced = Array(flow[start..<end])
        let replacedIds = Set(replaced.map(\.id))

        var assigned = [UUID?](repeating: nil, count: drafts.count)
        var used: Set<UUID> = []
        for (position, draft) in drafts.enumerated() {
            if let id = draft.id, replacedIds.contains(id), used.insert(id).inserted {
                assigned[position] = id
            }
        }

        // Сирота стоит в потоке страницы со своим контейнером и ключом из чужого потока: ключи соседей она не задаёт.
        func floats(_ block: Block) -> Bool { block.containerId != containerId }
        let lowerKey = flow[..<start].last { !floats($0) }?.sortKey
        let upperKey = flow[end...].first { !floats($0) }?.sortKey
        let replacedById = Dictionary(uniqueKeysWithValues: replaced.map { ($0.id, $0) })
        let floating: Set<Int> = Set(assigned.indices.filter { position in
            guard let id = assigned[position], let block = replacedById[id] else { return false }
            return floats(block) && !movedBlockIds.contains(id)
        })
        let existingKeys: [FractionalSortKey?] = assigned.enumerated().map { position, id in
            guard let id, !floating.contains(position), !movedBlockIds.contains(id), let block = replacedById[id], !floats(block)
            else { return nil }
            if let lowerKey, block.sortKey <= lowerKey { return nil }
            if let upperKey, block.sortKey >= upperKey { return nil }
            return block.sortKey
        }
        let kept = Self.longestIncreasingPositions(existingKeys)
        // Ближайший сохраняемый ключ ниже каждого места: между ним и предыдущим встают новые ключи.
        var nextKeptKey = [FractionalSortKey?](repeating: upperKey, count: drafts.count)
        var running = upperKey
        for position in drafts.indices.reversed() {
            nextKeptKey[position] = running
            if kept.contains(position) { running = existingKeys[position] }
        }

        var lastKey = lowerKey
        var newBlocks: [Block] = []
        for (position, draft) in drafts.enumerated() {
            let existing = assigned[position].flatMap { replacedById[$0] }
            var block = existing ?? Block(pageId: pageId, sortKey: .between(lastKey, upperKey), containerId: containerId)
            if !floating.contains(position) {
                block.containerId = containerId
                if kept.contains(position), let key = existingKeys[position] {
                    block.sortKey = key
                } else {
                    block.sortKey = .between(lastKey, nextKeptKey[position])
                }
                lastKey = block.sortKey
            }
            draft.apply(to: &block, isNew: existing == nil)
            newBlocks.append(block)
        }

        let removed = replaced.filter { !used.contains($0.id) }.map(\.id)
        let removedWithContents = removed + removed.flatMap(contents(of:))
        let removedFlows = removedWithContents.filter { flowOrder[$0] != nil }
        for id in removedWithContents {
            byId[id] = nil
            flowOrder[id] = nil
            unsavedBlockIds.remove(id)
            if savedBlocks[id] != nil { removedBlockIds.insert(id) }
        }
        for block in newBlocks {
            removedBlockIds.remove(block.id)
            byId[block.id] = block
            if replacedById[block.id] != block { markEdited(block.id, current: block) }
        }

        if let containerId {
            var order = flow.map(\.id)
            order.replaceSubrange(start..<end, with: newBlocks.map(\.id))
            flowOrder[containerId] = order
        } else {
            blocks.replaceSubrange(start..<end, with: newBlocks)
            reindex()
        }
        if !newBlocks.isEmpty || !replaced.isEmpty { didEdit?() }

        var change = ExternalChange()
        change.removedBlockIds = Set(removedWithContents)
        for block in newBlocks {
            if let old = replacedById[block.id] {
                if old != block { change.changedBlockIds.insert(block.id) }
            } else {
                change.insertedBlockIds.insert(block.id)
            }
        }
        if let containerId, change.touchesBlocks { change.changedFlowIds.insert(containerId) }
        change.changedFlowIds.formUnion(removedFlows)
        postLocalEdits(change, origin: origin)
        return newBlocks.map(\.id)
    }

    /// Всё внутри контейнера: его поток и потоки контейнеров в нём.
    private func contents(of containerId: UUID) -> [UUID] {
        guard let order = flowOrder[containerId] else { return [] }
        return order + order.flatMap(contents(of:))
    }

    /// Места черновиков, чьи ключи можно оставить: самая длинная возрастающая цепочка ключей.
    private static func longestIncreasingPositions(_ keys: [FractionalSortKey?]) -> Set<Int> {
        var tails: [Int] = []
        var previous = [Int?](repeating: nil, count: keys.count)
        for (position, key) in keys.enumerated() {
            guard let key else { continue }
            var low = 0, high = tails.count
            while low < high {
                let middle = (low + high) / 2
                if keys[tails[middle]]! < key { low = middle + 1 } else { high = middle }
            }
            previous[position] = low > 0 ? tails[low - 1] : nil
            if low == tails.count { tails.append(position) } else { tails[low] = position }
        }
        var kept: Set<Int> = []
        var position = tails.last
        while let current = position {
            kept.insert(current)
            position = previous[current]
        }
        return kept
    }

    /// Взять за основу правки текст блока, который сейчас лежит в базе: после выбора версии в «Двух версиях»
    /// следующая запись ложится поверх него, а не становится новым конфликтом.
    public func adoptStoredTextVersion(ofBlock blockId: UUID) {
        guard var block = byId[blockId], let saved = savedBlocks[blockId] else { return }
        block.textBaseClock = saved.fieldClocks.text
        put(block)
        markEdited(blockId)
        if unsavedBlockIds.contains(blockId) { didEdit?() }
    }

    // MARK: Правки из базы, сделанные не этим документом (research R5)

    /// Что поменялось в документе от внешних правок — редактор перерисовывает только это.
    public struct ExternalChange: Sendable, Hashable {
        public var changedBlockIds: Set<UUID> = []
        public var insertedBlockIds: Set<UUID> = []
        public var removedBlockIds: Set<UUID> = []
        /// Контейнеры, чей поток поменялся: блоки внутри, их порядок или состав.
        public var changedFlowIds: Set<UUID> = []
        public var titleChanged = false
        public var iconChanged = false
        public var conflictsChanged = false

        public var touchesBlocks: Bool { !changedBlockIds.isEmpty || !insertedBlockIds.isEmpty || !removedBlockIds.isEmpty }
        public var isEmpty: Bool { !touchesBlocks && !titleChanged && !iconChanged && !conflictsChanged }
    }

    /// После правки из редактора (`setTitle`, `replaceBlocks`): `object` — документ, `userInfo[externalChangeKey]` —
    /// что поменялось, `userInfo[editOriginKey]` — `ObjectIdentifier` того, кто правил. Другие окна этой же страницы
    /// (FR-029) перерисовывают затронутое; тот, кто правил, свой текст уже показывает.
    public static let didApplyLocalEdits = Notification.Name("PageDocument.didApplyLocalEdits")
    public static let editOriginKey = "origin"

    private func postLocalEdits(_ change: ExternalChange, origin: AnyObject?) {
        guard !change.isEmpty else { return }
        var userInfo: [String: any Sendable] = [Self.externalChangeKey: change]
        if let origin { userInfo[Self.editOriginKey] = ObjectIdentifier(origin) }
        NotificationCenter.default.post(name: Self.didApplyLocalEdits, object: self, userInfo: userInfo)
    }

    /// После `applyExternalChanges`; `object` — документ, `userInfo[externalChangeKey]` — `ExternalChange`.
    public static let didApplyExternalChanges = Notification.Name("PageDocument.didApplyExternalChanges")
    public static let externalChangeKey = "change"

    /// Принять то, что сейчас лежит в базе (пришло с другого Mac или из импорта). Несохранённые правки этого окна
    /// остаются: в блоке, который правится, свои поля не трогаются, и автосохранение потом сверит текст
    /// с версией начала правки (research R4). Порядок блоков — по ключам, поэтому свои новые блоки встают на места.
    @discardableResult
    public func applyExternalChanges(_ content: PageContent, conflicts: [Conflict]) -> ExternalChange {
        var change = ExternalChange()

        let stored = content.page
        if !isTitleUnsaved, page.title != stored.title {
            page.title = stored.title
            change.titleChanged = true
        }
        if page.icon != stored.icon {
            page.icon = stored.icon
            change.iconChanged = true
        }
        let ownTitle = page.title
        page = stored
        page.title = isTitleUnsaved ? ownTitle : stored.title
        savedPage = stored
        isTitleUnsaved = page.title != savedPage.title

        let storedById = Dictionary(uniqueKeysWithValues: content.blocks.map { ($0.id, $0) })
        let oldById = byId
        let oldPageOrder = blocks.map(\.id)
        let oldFlowOrder = flowOrder
        var merged: [Block] = []
        for block in content.blocks where !removedBlockIds.contains(block.id) {
            if unsavedBlockIds.contains(block.id), let local = oldById[block.id], let base = savedBlocks[block.id] {
                let (shown, saved) = Self.threeWayMerge(local: local, base: base, stored: block)
                merged.append(shown)
                savedBlocks[block.id] = saved
            } else {
                merged.append(block)
                savedBlocks[block.id] = block
            }
        }
        // Свои несохранённые блоки, которых в базе нет (новые или стёртые там): автосохранение запишет их целиком.
        for block in byId.values where storedById[block.id] == nil && unsavedBlockIds.contains(block.id) {
            merged.append(block)
        }
        for id in Array(savedBlocks.keys) where storedById[id] == nil {
            savedBlocks[id] = nil
            removedBlockIds.remove(id)
        }
        removedBlockIds.formIntersection(storedById.keys)
        byId = Dictionary(uniqueKeysWithValues: merged.map { ($0.id, $0) })
        removedContainers = content.removedContainers
        rebuildFlows()

        let newIds = Set(merged.map(\.id))
        for block in merged {
            if let old = oldById[block.id] {
                if !old.hasSameContent(as: block) { change.changedBlockIds.insert(block.id) }
            } else {
                change.insertedBlockIds.insert(block.id)
            }
        }
        change.removedBlockIds = Set(oldById.keys).subtracting(newIds)
        let pageOrder = blocks.map(\.id)
        if oldPageOrder.filter(newIds.contains) != pageOrder.filter(oldById.keys.contains) {
            for id in pageOrder where oldById[id] != nil { change.changedBlockIds.insert(id) }
        }
        // Блок ушёл из потока страницы в колонку или вернулся из неё: его абзац меняется.
        let pageMembers = Set(pageOrder)
        for id in oldPageOrder where newIds.contains(id) && !pageMembers.contains(id) { change.changedBlockIds.insert(id) }
        let touched = change.changedBlockIds.union(change.insertedBlockIds).union(change.removedBlockIds)
        for containerId in Set(oldFlowOrder.keys).union(flowOrder.keys) {
            let old = oldFlowOrder[containerId] ?? []
            let new = flowOrder[containerId] ?? []
            if old != new || new.contains(where: touched.contains) { change.changedFlowIds.insert(containerId) }
        }

        if conflicts != pendingConflicts {
            pendingConflicts = conflicts
            change.conflictsChanged = true
        }
        if !change.isEmpty {
            NotificationCenter.default.post(name: Self.didApplyExternalChanges, object: self,
                                            userInfo: [Self.externalChangeKey: change])
        }
        return change
    }

    /// Новый список «Двух версий» (после выбора версии): редактор перерисует метки.
    public func replacePendingConflicts(_ conflicts: [Conflict]) {
        guard conflicts != pendingConflicts else { return }
        pendingConflicts = conflicts
        var change = ExternalChange()
        change.conflictsChanged = true
        NotificationCenter.default.post(name: Self.didApplyExternalChanges, object: self, userInfo: [Self.externalChangeKey: change])
    }

    /// Блок, который правится здесь и изменился в базе: свои изменённые поля — свои, остальные — из базы.
    /// Возвращает, что показать, и с чем потом сравнивать автосохранению (свои поля — по старой основе).
    private static func threeWayMerge(local: Block, base: Block, stored: Block) -> (shown: Block, saved: Block) {
        let edited = local.changedFields(comparedTo: base)
        var shown = stored
        var saved = stored
        if edited.contains(.kindAndIndent) {
            shown.kind = local.kind
            shown.indent = local.indent
            shown.linkedPageId = local.linkedPageId
            saved.kind = base.kind
            saved.indent = base.indent
            saved.linkedPageId = base.linkedPageId
        }
        if edited.contains(.isChecked) || edited.contains(.kindAndIndent) {
            shown.isChecked = local.isChecked
            saved.isChecked = base.isChecked
        }
        if edited.contains(.placement) {
            shown.sortKey = local.sortKey
            shown.containerId = local.containerId
            saved.sortKey = base.sortKey
            saved.containerId = base.containerId
        }
        if edited.contains(.color) {
            shown.color = local.color
            saved.color = base.color
        }
        if edited.contains(.props) {
            shown.props = local.props
            saved.props = base.props
        }
        if edited.contains(.text) {
            shown.text = local.text
            shown.textBaseClock = local.textBaseClock
            saved.text = base.text
        }
        return (shown, saved)
    }

    // MARK: Запись

    /// Что записать: снимок накопленных правок.
    func unsavedChanges() -> PageDocumentChanges {
        PageDocumentChanges(
            title: isTitleUnsaved ? page.title : nil,
            upserted: unsavedBlockIds.compactMap { id in
                byId[id].map { (current: $0, saved: savedBlocks[id]) }
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
            guard var block = byId[id] else { continue }
            block.fieldClocks = stored.fieldClocks
            if !result.conflictedBlockIds.contains(id) {
                block.textBaseClock = stored.textBaseClock
            }
            put(block)
        }
    }

    // MARK: Внутреннее

    private func markEdited(_ id: UUID, current: Block? = nil) {
        guard let current = current ?? byId[id] else { return }
        if let saved = savedBlocks[id], saved.hasSameContent(as: current) {
            unsavedBlockIds.remove(id)
        } else {
            unsavedBlockIds.insert(id)
        }
    }

    private func reindex() {
        indexById = Dictionary(uniqueKeysWithValues: blocks.enumerated().map { ($1.id, $0) })
    }

    /// Записать блок в документ: в общий словарь и, если он в потоке страницы, в `blocks`.
    private func put(_ block: Block) {
        byId[block.id] = block
        if let index = indexById[block.id] { blocks[index] = block }
    }

    /// Разложить блоки по потокам. Сирота — блок, чьего контейнера в документе нет: она встаёт в поток страницы
    /// сразу за своим `columnList` или `table` (их находит цепочка контейнеров, в том числе удалённых),
    /// а без них — в конце страницы.
    private func rebuildFlows() {
        func ordered(_ items: [Block]) -> [Block] {
            items.sorted { $0.sortKey != $1.sortKey ? $0.sortKey < $1.sortKey : $0.id.uuidString < $1.id.uuidString }
        }
        var pageFlow: [Block] = []
        var flows: [UUID: [Block]] = [:]
        var orphans: [Block] = []
        for block in byId.values {
            if let containerId = block.containerId {
                if byId[containerId] != nil { flows[containerId, default: []].append(block) } else { orphans.append(block) }
            } else {
                pageFlow.append(block)
            }
        }
        pageFlow = ordered(pageFlow)
        flowOrder = flows.mapValues { ordered($0).map(\.id) }

        let pageIds = Set(pageFlow.map(\.id))
        var anchored: [UUID: [Block]] = [:]
        var atEnd: [Block] = []
        for orphan in ordered(orphans) {
            if let anchor = anchor(of: orphan, pageIds: pageIds) { anchored[anchor, default: []].append(orphan) } else { atEnd.append(orphan) }
        }
        blocks = pageFlow.flatMap { [$0] + (anchored[$0.id] ?? []) } + atEnd
        reindex()
    }

    /// Блок потока страницы, за которым показать сироту: первый предок по цепочке контейнеров, стоящий в потоке страницы.
    private func anchor(of orphan: Block, pageIds: Set<UUID>) -> UUID? {
        var current = orphan.containerId
        var visited: Set<UUID> = []
        while let id = current, visited.insert(id).inserted {
            if let live = byId[id] {
                if pageIds.contains(id) { return id }
                current = live.containerId
            } else if let parent = removedContainers[id] {
                current = parent
            } else {
                return nil
            }
        }
        return nil
    }
}

/// Желаемое содержимое блока из редактора. `id` — какой блок это был в тексте, если известно.
/// Место блока (поток и порядок) задаёт `replaceBlocks`, а не черновик.
public struct BlockDraft: Sendable, Hashable {
    public var id: UUID?
    public var kind: BlockKind
    public var text: InlineText
    public var indent: Int
    public var isChecked: Bool
    public var linkedPageId: UUID?
    /// Цвет блока; `nil` — оставить, какой есть (у нового блока — по умолчанию для типа). Черновик из текста абзаца
    /// цвета не знает, и правка текста его не стирает.
    public var color: BlockColor?
    /// Свойства по типу; `nil` — как у `color`.
    public var props: BlockProps?

    public init(id: UUID?, kind: BlockKind = .paragraph, text: InlineText = .empty, indent: Int = 0,
                isChecked: Bool = false, linkedPageId: UUID? = nil, color: BlockColor? = nil, props: BlockProps? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.indent = indent
        self.isChecked = isChecked
        self.linkedPageId = linkedPageId
        self.color = color
        self.props = props
    }

    /// Черновик, повторяющий блок.
    public init(_ block: Block) {
        self.init(id: block.id, kind: block.kind, text: block.text.normalized(), indent: block.indent,
                  isChecked: block.isChecked, linkedPageId: block.linkedPageId, color: block.color, props: block.props)
    }

    func apply(to block: inout Block, isNew: Bool) {
        // Ссылка без страницы — просто абзац: иначе блок нельзя записать.
        let kind = kind == .pageLink && linkedPageId == nil ? .paragraph : kind
        block.kind = kind
        block.text = text.normalized()
        // Заголовок вкладывается только внутрь переключателя, выноски, цитаты: это решает редактор по соседям
        // (`BlockMoveController`), а лишнее после слияния урезается при показе (`BlockNesting`).
        block.indent = min(max(indent, Block.indentRange.lowerBound), Block.indentRange.upperBound)
        block.isChecked = kind == .checkbox && isChecked
        block.linkedPageId = kind == .pageLink ? linkedPageId : nil
        if let color { block.color = color } else if isNew { block.color = .defaults(for: kind) }
        if let props { block.props = props } else if isNew { block.props = .defaults(for: kind) }
    }
}

extension Block {
    /// Совпадает всё, что пишет автосохранение (метки часов не в счёт).
    func hasSameContent(as other: Block) -> Bool {
        kind == other.kind && text.normalized() == other.text.normalized() && indent == other.indent
            && isChecked == other.isChecked && linkedPageId == other.linkedPageId && sortKey == other.sortKey
            && containerId == other.containerId && color == other.color && props == other.props
    }
}
