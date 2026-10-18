import Foundation
import NotesCore

/// Что Юрий должен узнать после слияния (крайние случаи spec, FR-021).
public enum SyncNotice: Sendable, Hashable {
    /// Страница, убранная в корзину, вернулась: её правили на другом Mac, не зная о корзине.
    case pageReturnedFromTrash(pageId: UUID, title: String)
    /// Страницу стёрли навсегда, не видя правок, — она возвращена в корзину на всех Mac.
    case pageRevivedInTrash(pageId: UUID, title: String)
    /// Один блок правили на двух Mac — «Две версии».
    case textConflict(pageId: UUID, blockId: UUID)

    public var message: String {
        switch self {
        case .pageReturnedFromTrash(_, let title):
            "Страница «\(Page.titleForMessages(title))» возвращена из корзины: её правили на другом Mac"
        case .pageRevivedInTrash(_, let title):
            "Страница «\(Page.titleForMessages(title))» была стёрта на другом Mac, но её правили — она в корзине, ничего не потеряно"
        case .textConflict:
            "Один блок правили на двух Mac — обе версии сохранены, выберите нужную"
        }
    }
}

/// Итог применения пачек: уведомления и страницы, которые поменялись (для окон).
public struct MergeReport: Sendable {
    public var notices: [SyncNotice] = []
    public var touchedPageIds: Set<UUID> = []

    public init(notices: [SyncNotice] = [], touchedPageIds: Set<UUID> = []) {
        self.notices = notices
        self.touchedPageIds = touchedPageIds
    }

    public static func += (lhs: inout MergeReport, rhs: MergeReport) {
        lhs.notices += rhs.notices
        lhs.touchedPageIds.formUnion(rhs.touchedPageIds)
    }
}

/// Слияние пришедших изменений с записями этого Mac (research R8). Каждая пачка — одна транзакция хранилища,
/// поэтому поиск и очередь исходящих видят результат сразу. Применение одной пачки дважды ничего не меняет.
public struct ChangeMerger: Sendable {
    public let localDeviceName: String

    public init(localDeviceName: String) {
        self.localDeviceName = localDeviceName
    }

    public func apply(_ batch: SyncBatch, in transaction: NotesTransaction) throws -> MergeReport {
        var run = MergeRun(transaction: transaction, sourceDeviceName: batch.deviceName, localDeviceName: localDeviceName,
                           snapshotKnowledge: nil)
        try run.merge(batch.changes)
        return run.report
    }

    /// Снимок всех записей с другого Mac: как пачка, но у текста нет версии начала правки — вместо неё
    /// известное снимку (`knowledge`).
    public func apply(_ snapshot: SyncSnapshot, in transaction: NotesTransaction) throws -> MergeReport {
        var run = MergeRun(transaction: transaction, sourceDeviceName: "другом Mac", localDeviceName: localDeviceName,
                           snapshotKnowledge: snapshot.knowledge)
        try run.merge(snapshot.changes)
        return run.report
    }
}

private struct MergeRun {
    let transaction: NotesTransaction
    let sourceDeviceName: String
    let localDeviceName: String
    let snapshotKnowledge: ClockKnowledge?
    var report = MergeReport()
    /// Страницы, чьё место менялось в пачке: родитель до слияния.
    private var placementsInBatch: [UUID: UUID?] = [:]

    init(transaction: NotesTransaction, sourceDeviceName: String, localDeviceName: String, snapshotKnowledge: ClockKnowledge?) {
        self.transaction = transaction
        self.sourceDeviceName = sourceDeviceName
        self.localDeviceName = localDeviceName
        self.snapshotKnowledge = snapshotKnowledge
    }

    mutating func merge(_ changes: [SyncChange]) throws {
        // Свои следующие метки — позже всего пришедшего.
        for change in changes where change.hlc != .distantPast { transaction.clock.receive(change.hlc) }
        for group in Outbox.groupedByRecord(changes) {
            switch group[0].entity {
            case .page: try mergePage(group)
            case .block: try mergeBlock(group)
            }
        }
        try removeStaleLinks()
        try repairLoops()
        report.touchedPageIds.formUnion(Self.touchedPages(transaction.changes))
    }

    // MARK: Страница

    private mutating func mergePage(_ group: [SyncChange]) throws {
        let pageId = group[0].id
        let erase = group.last { $0.value == .erased }
        let fields = group.filter { $0.value != .erased }

        guard var page = try transaction.page(pageId) else {
            if let tombstone = try transaction.tombstone(ofPage: pageId) {
                // Стирание побеждает правки, сделанные до него; страницу целиком после него — возвращает.
                if let revived = Self.pageFromFullChanges(fields), fields.allSatisfy({ $0.hlc > tombstone.erasedAt }) {
                    try transaction.removeTombstone(ofPage: pageId)
                    try transaction.writeReplicatedPage(revived, changedFields: Set(Page.Field.allCases))
                    report.notices.append(.pageRevivedInTrash(pageId: pageId, title: revived.title))
                } else if let erase {
                    try transaction.writeTombstone(ofPage: pageId, erasedAt: erase.hlc, known: erase.known ?? ClockKnowledge())
                }
            } else if let created = Self.pageFromFullChanges(fields) {
                try transaction.writeReplicatedPage(created, changedFields: Set(Page.Field.allCases))
            } else if let erase {
                try transaction.writeTombstone(ofPage: pageId, erasedAt: erase.hlc, known: erase.known ?? ClockKnowledge())
            }
            return
        }

        let wasTrashed = page.trashedAt != nil
        if fields.contains(where: { $0.value.field == "placement" }), placementsInBatch[pageId] == nil {
            placementsInBatch[pageId] = .some(page.parentId)
        }
        var changed: Set<Page.Field> = []
        var trashing: SyncChange?
        for change in fields {
            switch change.value {
            case .title(let title) where change.hlc > (page.fieldClocks.title ?? .distantPast):
                page.title = title
                page.fieldClocks.title = change.hlc
                changed.insert(.title)
            case .icon(let icon) where change.hlc > (page.fieldClocks.icon ?? .distantPast):
                guard icon.map(NotesTransaction.isSingleEmoji) ?? true else { continue }
                page.icon = icon
                page.fieldClocks.icon = change.hlc
                changed.insert(.icon)
            case .placement(let parentId, let rawKey) where change.hlc > (page.fieldClocks.placement ?? .distantPast):
                guard let sortKey = FractionalSortKey(rawValue: rawKey), parentId != pageId else { continue }
                page.parentId = parentId
                page.sortKey = sortKey
                page.fieldClocks.placement = change.hlc
                changed.insert(.placement)
            case .trashedAt(let trashedAt) where change.hlc > (page.fieldClocks.trashedAt ?? .distantPast):
                page.trashedAt = trashedAt
                page.fieldClocks.trashedAt = change.hlc
                changed.insert(.trashedAt)
                trashing = trashedAt == nil ? nil : change
            default:
                break
            }
        }
        if !changed.isEmpty {
            page.updatedAt = Date()
            try transaction.writeReplicatedPage(page, changedFields: changed)
        }
        if wasTrashed, page.trashedAt == nil {
            report.notices.append(.pageReturnedFromTrash(pageId: pageId, title: page.title))
        }
        // Убрали в корзину, не видя правок этого Mac, — страница возвращается (research R8).
        if let trashing, try !isContentKnown(ofPage: pageId, to: trashing.known ?? ClockKnowledge()) {
            try returnFromTrash(page)
            report.notices.append(.pageReturnedFromTrash(pageId: pageId, title: page.title))
        }
        if let erase {
            try mergeErase(of: pageId, erase)
        }
    }

    /// Стёрли навсегда: если стёрший видел все правки этой страницы — стереть и здесь; иначе страница остаётся
    /// в корзине и уходит на все Mac целиком, с новыми метками (research R8).
    private mutating func mergeErase(of pageId: UUID, _ erase: SyncChange) throws {
        let known = erase.known ?? ClockKnowledge()
        if try isContentKnown(ofPage: pageId, to: known) {
            try transaction.eraseReplicatedPage(pageId, erasedAt: erase.hlc, known: known)
            return
        }
        guard var page = try transaction.page(pageId) else { return }
        if page.trashedAt == nil {
            page.trashedAt = Date()
            page = try transaction.updatePage(page)
            if let parentId = page.parentId, try transaction.page(parentId) != nil {
                try removeLinks(to: pageId, in: parentId)
            }
        }
        try transaction.restampPageWithBlocks(pageId)
        report.notices.append(.pageRevivedInTrash(pageId: pageId, title: page.title))
    }

    /// Все правки содержимого страницы на этом Mac были известны удалившему.
    private func isContentKnown(ofPage pageId: UUID, to known: ClockKnowledge) throws -> Bool {
        var stamps: [HybridTimestamp] = []
        if let page = try transaction.page(pageId) {
            stamps += [page.fieldClocks.title, page.fieldClocks.icon].compactMap { $0 }
        }
        for (block, _) in try transaction.blocks(ofPage: pageId, includingDeleted: true) {
            stamps += block.fieldClocks.all
        }
        return stamps.allSatisfy { $0 == .distantPast || known.covers($0) }
    }

    /// Вернуть страницу из корзины своей правкой: на прежнее место, ссылка — снова в родителе; если родителя нет — в корень.
    private func returnFromTrash(_ trashed: Page) throws {
        var page = trashed
        page.trashedAt = nil
        if let parentId = page.parentId, try transaction.page(parentId) == nil {
            let lastRootKey = try transaction.allPages().filter { $0.parentId == nil }.map(\.sortKey).max()
            page.parentId = nil
            page.sortKey = .between(lastRootKey, nil)
        }
        try transaction.updatePage(page)
        if let parentId = page.parentId {
            let blocks = try transaction.blocks(ofPage: parentId)
            if !blocks.contains(where: { $0.linkedPageId == page.id }) {
                try transaction.insertBlock(Block(pageId: parentId, kind: .pageLink, linkedPageId: page.id,
                                                  sortKey: .between(blocks.last?.sortKey, nil)))
            }
        }
    }

    private func removeLinks(to pageId: UUID, in parentId: UUID) throws {
        for block in try transaction.blocks(ofPage: parentId) where block.kind == .pageLink && block.linkedPageId == pageId {
            try transaction.deleteBlock(block.id)
        }
    }

    /// Страница из полного набора полей (новая или пришедшая целиком); `nil`, если полей не хватает.
    private static func pageFromFullChanges(_ changes: [SyncChange]) -> Page? {
        var title: (String, HybridTimestamp)?
        var icon: (String?, HybridTimestamp)?
        var placement: (UUID?, FractionalSortKey, HybridTimestamp)?
        var trashedAt: (Date?, HybridTimestamp)?
        for change in changes {
            switch change.value {
            case .title(let value): title = (value, change.hlc)
            case .icon(let value): icon = (value.flatMap { NotesTransaction.isSingleEmoji($0) ? $0 : nil }, change.hlc)
            case .placement(let parentId, let raw):
                if let key = FractionalSortKey(rawValue: raw) { placement = (parentId == change.id ? nil : parentId, key, change.hlc) }
            case .trashedAt(let value): trashedAt = (value, change.hlc)
            default: break
            }
        }
        guard let title, let icon, let placement, let trashedAt, let id = changes.first?.id else { return nil }
        let now = Date()
        return Page(id: id, title: title.0, icon: icon.0, parentId: placement.0, sortKey: placement.1, trashedAt: trashedAt.0,
                    createdAt: now, updatedAt: now,
                    fieldClocks: PageFieldClocks(title: title.1, icon: icon.1, placement: placement.2, trashedAt: trashedAt.1))
    }

    // MARK: Блок

    private mutating func mergeBlock(_ group: [SyncChange]) throws {
        let blockId = group[0].id
        guard let stored = try transaction.block(blockId, includingDeleted: true) else {
            try insertBlock(group)
            return
        }
        guard try transaction.page(stored.block.pageId) != nil else { return }
        var block = stored.block
        var isDeleted = stored.isDeleted
        var changed: Set<Block.Field> = []
        var needsResend = false

        for change in group {
            switch change.value {
            case .kindAndIndent(let kind, let indent, let linkedPageId)
                where change.hlc > (block.fieldClocks.kindAndIndent ?? .distantPast):
                block.kind = kind
                block.indent = indent
                block.linkedPageId = linkedPageId
                block.fieldClocks.kindAndIndent = change.hlc
                changed.insert(.kindAndIndent)
            case .isChecked(let checked) where change.hlc > (block.fieldClocks.isChecked ?? .distantPast):
                block.isChecked = checked
                block.fieldClocks.isChecked = change.hlc
                changed.insert(.isChecked)
            case .sortKey(let raw) where change.hlc > (block.fieldClocks.sortKey ?? .distantPast):
                guard let key = FractionalSortKey(rawValue: raw) else { continue }
                block.sortKey = key
                block.fieldClocks.sortKey = change.hlc
                changed.insert(.sortKey)
            case .text(let text):
                if try mergeText(text, change, into: &block) {
                    changed.insert(.text)
                    // Текст, правленный без знания об удалении, возвращает блок.
                    isDeleted = false
                }
            case .deleted:
                if isDeleted {
                    if change.hlc > (block.fieldClocks.deleted ?? .distantPast) {
                        block.fieldClocks.deleted = change.hlc
                        changed.insert(.deleted)
                    }
                } else if change.baseHlc == block.fieldClocks.text {
                    isDeleted = true
                    block.fieldClocks.deleted = change.hlc
                    changed.insert(.deleted)
                } else {
                    // Удалили, не видя правки текста здесь: блок остаётся и уходит на другие Mac целиком.
                    needsResend = true
                }
            case .conflictResolved(let versions):
                let chosen = Set(versions)
                for conflict in try transaction.pendingConflicts(ofBlock: blockId)
                where chosen.isSuperset(of: [conflict.localVersion, conflict.remoteVersion]) {
                    try transaction.markConflictResolved(conflict)
                    report.touchedPageIds.insert(block.pageId)
                }
            default:
                break
            }
        }
        let wasDeleted = stored.isDeleted
        if !changed.isEmpty || wasDeleted != isDeleted {
            Self.makeConsistent(&block)
            try transaction.writeReplicatedBlock(block, isDeleted: isDeleted, changedFields: changed)
        }
        if needsResend, !isDeleted {
            try transaction.restampBlock(blockId)
        }
    }

    /// Текст блока (research R8). `true` — текст в базе поменялся.
    private mutating func mergeText(_ incoming: InlineText, _ change: SyncChange, into block: inout Block) throws -> Bool {
        guard let local = block.fieldClocks.text else {
            setText(incoming, change.hlc, of: &block)
            return true
        }
        if local == change.hlc { return false }
        let fastForward = change.baseHlc.map { $0 == local } ?? (snapshotKnowledge?.covers(local) ?? false)
        if fastForward || local == .distantPast {
            setText(incoming, change.hlc, of: &block)
            return true
        }
        if block.text == incoming {
            guard change.hlc > local else { return false }
            setText(incoming, change.hlc, of: &block)
            return true
        }
        // Обе стороны правили текст, не видя друг друга: в блоке — более поздняя версия, вторая — в конфликте.
        let incomingWins = change.hlc > local
        let shown = incomingWins ? incoming : block.text
        let other = incomingWins ? block.text : incoming
        let otherDevice = incomingWins ? deviceName(of: local) : sourceDeviceName
        if incomingWins { setText(incoming, change.hlc, of: &block) }
        if try transaction.addConflict(blockId: block.id, shownVersion: shown, otherVersion: other, otherDeviceName: otherDevice) {
            report.notices.append(.textConflict(pageId: block.pageId, blockId: block.id))
            report.touchedPageIds.insert(block.pageId)
        }
        return incomingWins
    }

    private func setText(_ text: InlineText, _ stamp: HybridTimestamp, of block: inout Block) {
        block.text = text
        block.fieldClocks.text = stamp
        block.textBaseClock = stamp
    }

    private func deviceName(of stamp: HybridTimestamp) -> String {
        stamp.deviceId == transaction.clock.deviceId ? localDeviceName : "другом Mac"
    }

    /// Блока здесь нет: он новый или пришёл целиком.
    private mutating func insertBlock(_ group: [SyncChange]) throws {
        guard let pageId = group.lazy.compactMap(\.pageId).first, try transaction.page(pageId) != nil else { return }
        var kind: (BlockKind, Int, UUID?, HybridTimestamp)?
        var text: (InlineText, HybridTimestamp)?
        var checked: (Bool, HybridTimestamp)?
        var sortKey: (FractionalSortKey, HybridTimestamp)?
        var deleted: HybridTimestamp?
        for change in group {
            switch change.value {
            case .kindAndIndent(let value, let indent, let link): kind = (value, indent, link, change.hlc)
            case .text(let value): text = (value, change.hlc)
            case .isChecked(let value): checked = (value, change.hlc)
            case .sortKey(let raw): if let key = FractionalSortKey(rawValue: raw) { sortKey = (key, change.hlc) }
            case .deleted: deleted = change.hlc
            default: break
            }
        }
        guard let kind, let text, let checked, let sortKey else { return }
        var block = Block(id: group[0].id, pageId: pageId, kind: kind.0, text: text.0, indent: kind.1, isChecked: checked.0,
                          linkedPageId: kind.2, sortKey: sortKey.0,
                          fieldClocks: BlockFieldClocks(kindAndIndent: kind.3, text: text.1, isChecked: checked.1,
                                                        sortKey: sortKey.1, deleted: deleted),
                          textBaseClock: text.1)
        Self.makeConsistent(&block)
        try transaction.writeReplicatedBlock(block, isDeleted: deleted != nil, changedFields: Set(Block.Field.allCases))
    }

    /// Поля, пришедшие с разных Mac, могут не сочетаться (отметка у абзаца, отступ у заголовка):
    /// приводятся к допустимым одинаково на всех Mac.
    private static func makeConsistent(_ block: inout Block) {
        if block.kind == .pageLink, block.linkedPageId == nil { block.kind = .paragraph }
        if block.kind != .pageLink { block.linkedPageId = nil }
        if block.kind != .checkbox { block.isChecked = false }
        block.indent = block.kind.isHeading ? 0 : min(max(block.indent, Block.indentRange.lowerBound), Block.indentRange.upperBound)
    }

    // MARK: Ссылки на подстраницы

    /// Подстраницу переносили: ссылка на неё остаётся только в нынешнем родителе. Убираются ссылки в прежнем
    /// родителе и пришедшие в этой пачке ссылки из проигравшего переноса — так же решает каждый Mac.
    private func removeStaleLinks() throws {
        guard !placementsInBatch.isEmpty else { return }
        var arrivedLinks: [UUID: [Block]] = [:]
        for change in transaction.changes.blocks {
            if case .saved(let block, _, true) = change, block.kind == .pageLink, let target = block.linkedPageId {
                arrivedLinks[target, default: []].append(block)
            }
        }
        for (pageId, previousParent) in placementsInBatch {
            guard let page = try transaction.page(pageId) else { continue }
            var candidates = arrivedLinks[pageId] ?? []
            if let previousParent, previousParent != page.parentId {
                candidates += try transaction.blocks(ofPage: previousParent).filter { $0.linkedPageId == pageId }
            }
            var removed: Set<UUID> = []
            for link in candidates where link.pageId != page.parentId && removed.insert(link.id).inserted {
                if try transaction.block(link.id) != nil { try transaction.deleteBlock(link.id) }
            }
        }
    }

    // MARK: Петли в дереве

    /// Переносы с двух Mac сложились в петлю (страница внутри своей подстраницы): из петли выходит страница
    /// с самым поздним переносом — его и отклоняем; она встаёт в корень. Решение зависит только от полей,
    /// поэтому на всех Mac одинаково (research R8).
    private func repairLoops() throws {
        let pages = try transaction.allPages()
        let byId = Dictionary(uniqueKeysWithValues: pages.map { ($0.id, $0) })
        var settled: Set<UUID> = []
        for start in pages where !settled.contains(start.id) {
            var path: [UUID] = []
            var onPath: Set<UUID> = []
            var current: UUID? = start.id
            while let id = current, !settled.contains(id) {
                if onPath.contains(id) {
                    let loop = path.drop(while: { $0 != id })
                    if let victim = loop.compactMap({ byId[$0] }).max(by: Self.placementOrder) {
                        var detached = victim
                        detached.parentId = nil
                        try transaction.writeReplicatedPage(detached, changedFields: [.placement])
                        if let oldParent = victim.parentId, byId[oldParent] != nil {
                            try removeLinks(to: victim.id, in: oldParent)
                        }
                    }
                    break
                }
                path.append(id)
                onPath.insert(id)
                current = byId[id]?.parentId.flatMap { byId[$0] == nil ? nil : $0 }
            }
            settled.formUnion(path)
        }
    }

    private static func placementOrder(_ lhs: Page, _ rhs: Page) -> Bool {
        let left = lhs.fieldClocks.placement ?? .distantPast
        let right = rhs.fieldClocks.placement ?? .distantPast
        return left != right ? left < right : lhs.id.uuidString < rhs.id.uuidString
    }

    private static func touchedPages(_ changes: NotesChanges) -> Set<UUID> {
        var touched = Set(changes.pages.map(\.page.id))
        touched.formUnion(changes.erasedPageIds)
        for change in changes.blocks {
            switch change {
            case .saved(let block, _, _): touched.insert(block.pageId)
            case .erased(_, let pageId): touched.insert(pageId)
            }
        }
        return touched
    }
}

extension Page {
    /// Название для сообщений: пустое — «Без названия».
    static func titleForMessages(_ title: String) -> String { title.isEmpty ? untitledTitle : title }
}
