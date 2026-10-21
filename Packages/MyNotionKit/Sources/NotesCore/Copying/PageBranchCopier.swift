import Foundation

/// Копия страницы с подстраницами в одной транзакции (research R7, contracts/page-operations.md, «Дублирование»):
/// новые id страниц и блоков; ссылки-подстраницы на страницы ветки ведут на копии, остальные и упоминания — как были;
/// у дат копии напоминания выключены; файлы — та же `AttachmentRef` (байты не копируются, счётчик ссылок 002 видит копию).
/// Страницы ветки в корзине и ссылки на них не копируются. Избранное и открытие — не содержимое: у копии их нет.
public enum PageBranchCopier {
    public struct Result: Sendable {
        public let rootId: UUID
        /// id исходной страницы → id копии.
        public let pageIds: [UUID: UUID]
        /// id исходного блока → id копии, по всем страницам ветки.
        public let blockIds: [UUID: UUID]
    }

    /// `title`, `parentId`, `sortKey` — для корня копии. `now` — момент создания для дат шаблона «@сегодня» и «@сейчас»;
    /// `resolvesTemplateDates: false` — копия шаблона-шаблоном, даты остаются относительными (по умолчанию — так, если
    /// копируется шаблон). `rootIsTemplate` — отметка «шаблон» у корня копии (по умолчанию — как у оригинала).
    /// `fillingPage` — вместо новой страницы корень копии пишется в эту уже существующую пустую страницу: её поля
    /// заменяются полями оригинала, блоки добавляются, `parentId` и `sortKey` не используются (шаблоны, US7).
    public static func copy(_ rootId: UUID, in transaction: NotesTransaction, title: String, parentId: UUID?, sortKey: FractionalSortKey,
                            now: Date = Date(), resolvesTemplateDates: Bool? = nil, rootIsTemplate: Bool? = nil,
                            fillingPage existingRootId: UUID? = nil) throws -> Result {
        let all = try transaction.allPages()
        guard let root = all.first(where: { $0.id == rootId }) else { throw NotesStoreError.pageNotFound(rootId) }
        let children = Dictionary(grouping: all.filter { $0.trashedAt == nil }, by: \.parentId)
        var branch: [Page] = []
        func collect(_ page: Page) {
            branch.append(page)
            for child in (children[page.id] ?? []).sorted(by: { $0.sortKey < $1.sortKey }) { collect(child) }
        }
        collect(root)
        var pageIds: [UUID: UUID] = [:]
        for page in branch { pageIds[page.id] = (page.id == rootId ? existingRootId : nil) ?? .timeOrdered() }
        let trashedInBranch = Set(all.filter { $0.trashedAt != nil && $0.parentId.map { pageIds[$0] != nil } == true }.map(\.id))
        let resolvesDates = resolvesTemplateDates ?? !root.isTemplate

        var blockIds: [UUID: UUID] = [:]
        for page in branch {
            let isRoot = page.id == rootId
            var copy = Page(id: pageIds[page.id]!, title: isRoot ? title : page.title, icon: page.icon,
                            parentId: isRoot ? parentId : page.parentId.flatMap { pageIds[$0] },
                            sortKey: isRoot ? sortKey : page.sortKey, createdAt: now, updatedAt: now, cover: page.cover,
                            isFullWidth: page.isFullWidth, isSmallText: page.isSmallText,
                            isTemplate: isRoot ? rootIsTemplate ?? page.isTemplate : page.isTemplate)
            if isRoot, existingRootId != nil {
                guard var existing = try transaction.page(copy.id) else { throw NotesStoreError.pageNotFound(copy.id) }
                existing.title = copy.title
                existing.icon = copy.icon
                existing.cover = copy.cover
                existing.isFullWidth = copy.isFullWidth
                existing.isSmallText = copy.isSmallText
                existing.isTemplate = copy.isTemplate
                copy = try transaction.updatePage(existing)
            } else {
                try transaction.insertPage(copy)
            }
            let blocks = try transaction.blocks(ofPage: page.id)
                .filter { !($0.kind == .pageLink && $0.linkedPageId.map(trashedInBranch.contains) == true) }
            let flow = blocks.filter { $0.containerId == nil }.sorted(by: BlockCopier.flowOrder)
            var copied = BlockCopier.copy(flow, pageBlocks: blocks, into: copy.id, indentBase: 0)
            for index in copied.blocks.indices {
                // Страница копируется целиком: глубина и порядок потока — как у оригинала.
                copied.blocks[index].indent = copied.originals[index].indent
                copied.blocks[index].sortKey = copied.originals[index].sortKey
                if let linked = copied.blocks[index].linkedPageId, let target = pageIds[linked] { copied.blocks[index].linkedPageId = target }
                copied.blocks[index].text = copiedText(copied.blocks[index].text, now: now, resolvesTemplateDates: resolvesDates)
            }
            blockIds.merge(copied.newIds) { $1 }
            for block in copied.blocks { try transaction.insertBlock(block) }
        }
        return Result(rootId: pageIds[rootId]!, pageIds: pageIds, blockIds: blockIds)
    }

    /// Даты копии: свой id (он же id напоминания), напоминание выключено; дата шаблона — момент создания.
    static func copiedText(_ text: InlineText, now: Date, resolvesTemplateDates: Bool) -> InlineText {
        guard text.runs.contains(where: { if case .date = $0.style { true } else { false } }) else { return text }
        return InlineText(text.string, runs: text.runs.map { run in
            guard case .date(var date) = run.style else { return run }
            date.id = .timeOrdered()
            date.reminder = nil
            if resolvesTemplateDates, let relative = date.templateRelative {
                date.start = moment(now, timeZone: date.timeZone, includesTime: relative == .now)
                date.includesTime = relative == .now
                date.templateRelative = nil
            }
            return StyledRun(start: run.start, length: run.length, style: .date(date))
        })
    }

    /// `2026-10-20` или `2026-10-20T21:30` в поясе даты.
    static func moment(_ date: Date, timeZone: String, includesTime: Bool) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone) ?? .current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let day = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        return includesTime ? day + String(format: "T%02d:%02d", parts.hour ?? 0, parts.minute ?? 0) : day
    }
}
