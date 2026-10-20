import Foundation

/// «Дублировать» страницу (research R7, contracts/page-operations.md, «Дублирование»): копия ветки `PageBranchCopier`
/// сразу под оригиналом с названием «Название (1)» (занято у соседей — следующий свободный номер); в родителе ссылка
/// на копию — сразу за ссылкой на оригинал. Копия шаблона — шаблон, даты — как были. ⌘Z стирает копию навсегда.
extension PageTreeOperations {
    /// Копия пишется с очереди записи: ветка на тысячи блоков не замораживает окно (research R15, проба копии ветки).
    /// Возвращает корень копии.
    @discardableResult
    public func duplicate(_ pageId: UUID, now: Date = Date()) async throws -> Page {
        let copy = try await writeCopyOffMain(of: pageId, now: now)
        registerDuplicateUndo(copy.id, original: pageId)
        return copy
    }

    private func writeCopyOffMain(of pageId: UUID, now: Date) async throws -> Page {
        let store = store
        let (copy, touched) = try await Task.detached {
            try store.write { transaction in
                let copy = try Self.writeDuplicate(of: pageId, in: transaction, now: now)
                return (copy, Self.touchedPages(transaction.changes))
            }
        }.value
        onChange?(touched)
        return copy
    }

    private func registerDuplicateUndo(_ copyId: UUID, original: UUID) {
        registerUndo("Дублирование") { try $0.eraseDuplicate(copyId, original: original) }
    }

    /// Отмена: копия со всей веткой (и с тем, что в ней успели удалить в корзину) стирается, ссылка в родителе — тоже.
    private func eraseDuplicate(_ copyId: UUID, original: UUID) throws {
        try eraseBranch(copyId)
        registerUndo("Дублирование") { $0.redoDuplicate(original) }
    }

    func eraseBranch(_ copyId: UUID) throws {
        try perform { transaction in
            let all = try transaction.allPages()
            let children = Dictionary(grouping: all, by: \.parentId)
            var branch: [Page] = []
            func collect(_ page: Page) {
                branch.append(page)
                for child in children[page.id] ?? [] { collect(child) }
            }
            guard let copy = all.first(where: { $0.id == copyId }) else { throw NotesStoreError.pageNotFound(copyId) }
            collect(copy)
            try Self.erase(branch, transaction)
        }
    }

    /// Копия повтора, пока пишется: отменённая раньше готовности стирается, как только допишется.
    private final class RedoneCopy {
        let task: Task<Page, any Error>
        var copyId: UUID?
        var isWithdrawn = false
        init(task: Task<Page, any Error>) { self.task = task }
    }

    /// Повтор (⇧⌘Z): копия заново (стёртые id не возвращаются), тоже с очереди записи — главный поток не ждёт.
    /// Запись отмены ставится сразу: меню «Правка» ждёт её в том же шаге повтора.
    private func redoDuplicate(_ original: UUID) {
        let redone = RedoneCopy(task: Task { try await self.writeCopyOffMain(of: original, now: Date()) })
        pendingDuplicate = redone.task
        registerUndo("Дублирование") { try $0.withdrawRedone(redone, original: original) }
        Task { [weak self] in
            do {
                let copy = try await redone.task.value
                redone.copyId = copy.id
                if self?.pendingDuplicate == redone.task { self?.pendingDuplicate = nil }
                if !redone.isWithdrawn { self?.onDuplicateRedone?(copy) }
            } catch {
                self?.pendingDuplicate = nil
                self?.onUndoFailure?(error)
            }
        }
    }

    private func withdrawRedone(_ redone: RedoneCopy, original: UUID) throws {
        if let copyId = redone.copyId { return try eraseDuplicate(copyId, original: original) }
        redone.isWithdrawn = true
        pendingErase = Task { [weak self] in
            guard let copy = try? await redone.task.value else { return }
            do { try self?.eraseBranch(copy.id) } catch { self?.onUndoFailure?(error) }
        }
        registerUndo("Дублирование") { $0.redoDuplicate(original) }
    }

    nonisolated static func writeDuplicate(of pageId: UUID, in transaction: NotesTransaction, now: Date) throws -> Page {
        let all = try transaction.allPages()
        guard let original = all.first(where: { $0.id == pageId }) else { throw NotesStoreError.pageNotFound(pageId) }
        let siblings = all.filter { $0.parentId == original.parentId && $0.trashedAt == nil }.sorted(by: PageTreeSnapshot.siblingOrder)
        let next = siblings.drop { $0.id != pageId }.dropFirst().first?.sortKey
        let result = try PageBranchCopier.copy(
            pageId, in: transaction, title: duplicateTitle(original.displayTitle, taken: Set(siblings.map(\.displayTitle))),
            parentId: original.parentId, sortKey: .between(original.sortKey, next.flatMap { original.sortKey < $0 ? $0 : nil }),
            now: now, resolvesTemplateDates: false)
        if let parentId = original.parentId {
            try placeLink(to: result.rootId, after: pageId, in: parentId, transaction)
        }
        guard let copy = try transaction.page(result.rootId) else { throw NotesStoreError.pageNotFound(result.rootId) }
        return copy
    }

    /// «Название (1)»; занято — «(2)» и дальше.
    nonisolated static func duplicateTitle(_ title: String, taken: Set<String>) -> String {
        var number = 1
        while taken.contains("\(title) (\(number))") { number += 1 }
        return "\(title) (\(number))"
    }

    /// Ссылка на копию — в том же потоке и с тем же отступом сразу за ссылкой на оригинал; ссылки нет — в конец страницы.
    private nonisolated static func placeLink(to copyId: UUID, after originalId: UUID, in parentId: UUID,
                                              _ transaction: NotesTransaction) throws {
        let blocks = try transaction.blocks(ofPage: parentId)
        guard let link = blocks.first(where: { $0.kind == .pageLink && $0.linkedPageId == originalId }) else {
            let last = blocks.filter { $0.containerId == nil }.map(\.sortKey).max()
            try transaction.insertBlock(Block(pageId: parentId, kind: .pageLink, linkedPageId: copyId, sortKey: .between(last, nil)))
            return
        }
        let flow = blocks.filter { $0.containerId == link.containerId }.sorted(by: BlockCopier.flowOrder)
        let next = flow.drop { $0.id != link.id }.dropFirst().first?.sortKey
        try transaction.insertBlock(Block(pageId: parentId, kind: .pageLink, indent: link.indent, linkedPageId: copyId,
                                          sortKey: .between(link.sortKey, next.flatMap { link.sortKey < $0 ? $0 : nil }),
                                          containerId: link.containerId))
    }
}
