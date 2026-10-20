import Foundation

/// Шаблоны страниц (research R12, contracts/page-operations.md, «Шаблоны»): «Сделать шаблоном» уводит страницу в корень
/// и ставит отметку, «Перестать быть шаблоном» её снимает; пустая страница заполняется копией шаблона, «Новая страница
/// по шаблону» кладёт копию в корень. Копирует `PageBranchCopier`: «@сегодня» и «@сейчас» шаблона становятся моментом
/// создания копии, а правка шаблона прежних копий не меняет.
extension PageTreeOperations {
    // MARK: Сделать и перестать

    /// Страница с веткой — в корень последней, ссылка в прежнем родителе убрана, отметка поставлена; одна отмена.
    /// Уже шаблон — ничего не меняется.
    public func makeTemplate(_ pageId: UUID) throws {
        let previous = try perform { transaction -> Placement? in
            guard var page = try transaction.page(pageId) else { throw NotesStoreError.pageNotFound(pageId) }
            guard !page.isTemplate else { return nil }
            let previous = Placement(parentId: page.parentId, sortKey: page.sortKey, links: [])
            var links: [Block] = []
            if let oldParentId = page.parentId {
                links = try transaction.blocks(ofPage: oldParentId).filter { $0.kind == .pageLink && $0.linkedPageId == pageId }
                try Self.removeLinks(to: pageId, in: oldParentId, transaction)
                let lastRoot = try transaction.allPages().filter { $0.parentId == nil && $0.id != pageId }.map(\.sortKey).max()
                page.parentId = nil
                page.sortKey = .between(lastRoot, nil)
            }
            page.isTemplate = true
            try transaction.updatePage(page)
            return Placement(parentId: previous.parentId, sortKey: previous.sortKey, links: links)
        }
        guard let previous else { return }
        registerUndo("Сделать шаблоном") { try $0.revertMakeTemplate(pageId, to: previous) }
    }

    /// Отметка снята; страница остаётся в корне «Страниц». Не шаблон — ничего не меняется.
    public func stopBeingTemplate(_ pageId: UUID) throws {
        guard try setTemplateMark(false, of: pageId) else { return }
        registerUndo("Перестать быть шаблоном") { try $0.restoreTemplateMark(of: pageId) }
    }

    /// Прежнее место страницы, которую сделали шаблоном: родитель, порядок и убранные ссылки (те же блоки, те же id).
    struct Placement {
        let parentId: UUID?
        let sortKey: FractionalSortKey
        let links: [Block]
    }

    private func revertMakeTemplate(_ pageId: UUID, to previous: Placement) throws {
        try perform { transaction in
            guard var page = try transaction.page(pageId) else { throw NotesStoreError.pageNotFound(pageId) }
            page.isTemplate = false
            page.parentId = previous.parentId
            page.sortKey = previous.sortKey
            try transaction.updatePage(page)
            for link in previous.links where try transaction.block(link.id) == nil { try transaction.insertBlock(link) }
        }
        registerUndo("Сделать шаблоном") { try $0.makeTemplate(pageId) }
    }

    private func restoreTemplateMark(of pageId: UUID) throws {
        _ = try setTemplateMark(true, of: pageId)
        registerUndo("Перестать быть шаблоном") { try $0.stopBeingTemplate(pageId) }
    }

    /// `true`, если отметка поменялась.
    private func setTemplateMark(_ isTemplate: Bool, of pageId: UUID) throws -> Bool {
        try perform { transaction in
            guard var page = try transaction.page(pageId) else { throw NotesStoreError.pageNotFound(pageId) }
            guard page.isTemplate != isTemplate else { return false }
            page.isTemplate = isTemplate
            try transaction.updatePage(page)
            return true
        }
    }

    // MARK: Страница по шаблону

    /// Страница пуста: только пустые абзацы и ни одной подстраницы — под её тело можно положить шаблон. Название не считается.
    public func isEmptyForTemplate(_ pageId: UUID) throws -> Bool {
        guard let content = try store.pageContent(pageId) else { throw NotesStoreError.pageNotFound(pageId) }
        return Self.isEmpty(content.blocks, hasSubpages: !(try store.pageTree().children(of: pageId).isEmpty))
    }

    nonisolated static func isEmpty(_ blocks: [Block], hasSubpages: Bool) -> Bool {
        !hasSubpages && blocks.allSatisfy { $0.kind == .paragraph && $0.containerId == nil && $0.text.string.isEmpty }
    }

    /// Заполнить пустую страницу копией шаблона (название, иконка, обложка, вид, блоки, подстраницы-копии) одной правкой.
    /// `now` — момент создания для «@сегодня» и «@сейчас» шаблона.
    public func fill(_ pageId: UUID, fromTemplate templateId: UUID, now: Date = Date()) throws {
        let filled = try perform { transaction -> FilledPage in
            let all = try transaction.allPages()
            try Self.validateTemplate(templateId, for: pageId, in: all)
            guard let page = all.first(where: { $0.id == pageId }) else { throw NotesStoreError.pageNotFound(pageId) }
            let blocks = try transaction.blocks(ofPage: pageId)
            guard Self.isEmpty(blocks, hasSubpages: all.contains { $0.parentId == pageId && $0.trashedAt == nil }) else {
                throw NotesStoreError.invalidPage("шаблон кладут только на пустую страницу")
            }
            guard let template = all.first(where: { $0.id == templateId }) else { throw NotesStoreError.pageNotFound(templateId) }
            for block in blocks { try transaction.deleteBlock(block.id) }
            let result = try PageBranchCopier.copy(templateId, in: transaction, title: template.title, parentId: nil,
                                                    sortKey: page.sortKey, now: now, resolvesTemplateDates: true,
                                                    rootIsTemplate: false, fillingPage: pageId)
            return FilledPage(before: page, blocks: blocks, subpageIds: result.pageIds.filter { $0.key != templateId }.map(\.value))
        }
        registerUndo("Страница по шаблону") { try $0.unfill(pageId, fromTemplate: templateId, filled) }
    }

    /// Страница и её пустые блоки до заполнения; копии подстраниц, созданные заполнением.
    struct FilledPage {
        let before: Page
        let blocks: [Block]
        let subpageIds: [UUID]
    }

    private func unfill(_ pageId: UUID, fromTemplate templateId: UUID, _ filled: FilledPage) throws {
        try perform { transaction in
            let all = try transaction.allPages()
            let created = Set(filled.subpageIds)
            try Self.erase(all.filter { created.contains($0.id) }, transaction)
            for block in try transaction.blocks(ofPage: pageId) { try transaction.deleteBlock(block.id) }
            guard var page = try transaction.page(pageId) else { throw NotesStoreError.pageNotFound(pageId) }
            page.title = filled.before.title
            page.icon = filled.before.icon
            page.cover = filled.before.cover
            page.isFullWidth = filled.before.isFullWidth
            page.isSmallText = filled.before.isSmallText
            page.isTemplate = filled.before.isTemplate
            try transaction.updatePage(page)
            for block in filled.blocks { try transaction.insertBlock(block) }
        }
        registerUndo("Страница по шаблону") { try $0.fill(pageId, fromTemplate: templateId) }
    }

    /// «Новая страница по шаблону»: копия с подстраницами в корне последней, не шаблон. Возвращает корень копии; одна отмена.
    @discardableResult
    public func createPage(fromTemplate templateId: UUID, now: Date = Date()) throws -> Page {
        let created = try perform { transaction -> Page in
            let all = try transaction.allPages()
            try Self.validateTemplate(templateId, for: nil, in: all)
            guard let template = all.first(where: { $0.id == templateId }) else { throw NotesStoreError.pageNotFound(templateId) }
            let lastRoot = all.filter { $0.parentId == nil }.map(\.sortKey).max()
            let result = try PageBranchCopier.copy(templateId, in: transaction, title: template.title, parentId: nil,
                                                    sortKey: .between(lastRoot, nil), now: now, resolvesTemplateDates: true,
                                                    rootIsTemplate: false)
            guard let copy = try transaction.page(result.rootId) else { throw NotesStoreError.pageNotFound(result.rootId) }
            return copy
        }
        registerUndo("Новая страница по шаблону") { try $0.eraseTemplateCopy(created.id, template: templateId) }
        return created
    }

    private func eraseTemplateCopy(_ copyId: UUID, template templateId: UUID) throws {
        try eraseBranch(copyId)
        registerUndo("Новая страница по шаблону") { try $0.createPage(fromTemplate: templateId) }
    }

    /// Шаблон — страница с отметкой, не в корзине; на саму себя и на свою ветку его не кладут.
    private nonisolated static func validateTemplate(_ templateId: UUID, for pageId: UUID?, in all: [Page]) throws {
        let byId = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        guard let template = byId[templateId] else { throw NotesStoreError.pageNotFound(templateId) }
        guard template.isTemplate, !PageTreeSnapshot.isInTrash(template, pagesById: byId) else {
            throw NotesStoreError.invalidPage("страница не шаблон или лежит в корзине")
        }
        guard let pageId else { return }
        guard let page = byId[pageId] else { throw NotesStoreError.pageNotFound(pageId) }
        var current: Page? = page
        var steps = 0
        while let checked = current, steps <= all.count {
            if checked.id == templateId { throw NotesStoreError.invalidPage("шаблон нельзя положить на себя или на свою подстраницу") }
            current = checked.parentId.flatMap { byId[$0] }
            steps += 1
        }
    }
}
