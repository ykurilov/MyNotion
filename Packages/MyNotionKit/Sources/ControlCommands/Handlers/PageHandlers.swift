import ControlProtocol
import Foundation
import NotesCore
import NotionImport
import PageMarkdown

/// Страницы и корзина (этап 2, US1): дерево, чтение и запись Markdown, правки дерева через операции сессии.
/// Содержимое пишется через открытый документ страницы (research R3): окно, где страница открыта, видит правку сразу,
/// а незаписанный ввод человека в нём не теряется.
public enum PageHandlers {
    public static let all: [String: CommandHandler] = [
        "page.tree": tree, "page.get": get, "page.read": read, "page.create": create, "page.write": write,
        "page.append": append, "page.rename": rename, "page.move": move, "page.duplicate": duplicate,
        "page.trash": trash, "page.restore": restore, "page.layout": layout,
        "trash.list": trashList, "trash.delete": trashDelete, "trash.empty": trashEmpty,
    ]

    // MARK: Чтение

    static let tree: CommandHandler = { session in
        let outline = try PageOutline(store: session.host.store)
        let top = try session.optionalPage("page").map { outline.children(of: $0.id) } ?? outline.roots
        let depth = session.int("depth")
        return CommandResult(try session.paged(top.map { outline.node($0, depth: depth) }), text: "\(top.count) страниц")
    }

    static let get: CommandHandler = { session in
        let page = try session.page()
        return try session.pageResult(page.id)
    }

    static let read: CommandHandler = { session in
        let page = try session.page()
        // Без `--with-children` дерево целиком не читается: названия ссылок берутся по одному, страница — вместе с предками.
        guard session.flag("withChildren") else {
            guard let (_, json) = try PageQueries.response(for: page.id, in: session.host.store) else { throw NotesStoreError.pageNotFound(page.id) }
            var data = session.content(of: page.id, titles: session.storedTitles)
            data["page"] = json
            return CommandResult(.object(data), text: page.title)
        }
        let outline = try PageOutline(store: session.host.store)
        var data = session.content(of: page.id, outline: outline)
        data["page"] = outline.json(page)
        data["children"] = .array(outline.children(of: page.id).map { child in
            var item = session.content(of: child.id, outline: outline)
            item["page"] = outline.json(child)
            return .object(item)
        })
        return CommandResult(.object(data), text: page.title)
    }

    // MARK: Создание и содержимое

    static let create: CommandHandler = { session in
        let title = session.string("title") ?? ""
        let parent = try session.optionalPage("parent")
        let after = try session.optionalPage("after")
        let template = try session.optionalPage("template")
        if let template, !template.isTemplate {
            throw ControlError(.templateNotFound, "«\(template.title)» — не шаблон", hint: "Сделать шаблоном: «Сделать шаблоном» в меню страницы",
                               details: ["template": .string(template.id.controlText)])
        }
        if let after { try requireSibling(after, of: parent?.id) }
        let operations = session.pageTree
        let page = try parent.map { try operations.createSubpage(in: $0.id, title: title) } ?? operations.createRootPage(title: title)
        if let after {
            let siblings = try PageOutline(store: session.host.store).children(of: parent?.id).filter { $0.id != page.id }
            try operations.move(page.id, toParent: parent?.id, at: (siblings.firstIndex { $0.id == after.id } ?? siblings.count) + 1)
        }
        if let template {
            // Как «по шаблону» в окне: пустая страница заполняется копией шаблона, название — заданное.
            try operations.fill(page.id, fromTemplate: template.id, now: session.host.now)
            try operations.rename(page.id, to: title)
        }
        if let icon = session.string("icon") { try operations.setIcon(page.id, to: icon) }
        if let markdown = session.string("markdown") {
            try await session.replaceContent(of: page.id, with: markdown, checkpoint: false)
        }
        return try session.pageResult(page.id)
    }

    static let write: CommandHandler = { session in
        let page = try session.page()
        try await session.replaceContent(of: page.id, with: session.string("markdown") ?? "", checkpoint: true)
        return try session.pageResult(page.id)
    }

    static let append: CommandHandler = { session in
        let page = try session.page()
        let stored = try session.optionalBlock("after", inPage: page.id)
        let outline = try PageOutline(store: session.host.store)
        try outline.requireEditable(page)
        try await session.editContent(of: page.id, checkpoint: true) { document in
            let anchor = stored.map { document.block($0.id) ?? $0 } ?? document.blocks.filter { $0.containerId == nil }.max { $0.sortKey < $1.sortKey }
            let next = anchor.flatMap { anchor in
                document.blocks.filter { $0.containerId == anchor.containerId && $0.sortKey > anchor.sortKey }.map(\.sortKey).min()
            }
            var key = anchor?.sortKey
            let blocks = session.blocks(fromMarkdown: session.string("markdown") ?? "", pageId: page.id, existing: document.blocks,
                                        outline: outline).map { block in
                guard block.containerId == nil else { return block }
                var block = block
                key = .between(key, next)
                block.sortKey = key!
                block.containerId = anchor?.containerId
                return block
            }
            return BlockChanges(upserts: blocks)
        }
        return try session.pageResult(page.id)
    }

    // MARK: Правки дерева

    static let rename: CommandHandler = { session in
        let page = try session.page()
        try session.pageTree.rename(page.id, to: session.string("title") ?? "")
        return try session.pageResult(page.id)
    }

    static let move: CommandHandler = { session in
        let page = try session.page()
        let parentId: UUID? = try session.flag("root") ? nil : session.page("parent").id
        guard try session.pageTree.canMove(page.id, toParent: parentId) else {
            throw ControlError(.cannotMove, "Страницу нельзя положить внутрь себя или своей подстраницы",
                               hint: "Другой родитель или --root", details: ["page": .string(page.id.controlText)])
        }
        var index = Int.max
        if session.flag("first") {
            index = 0
        } else if let after = try session.optionalPage("after") {
            try requireSibling(after, of: parentId)
            let siblings = try PageOutline(store: session.host.store).children(of: parentId).filter { $0.id != page.id }
            index = (siblings.firstIndex { $0.id == after.id } ?? siblings.count) + 1
        }
        try session.pageTree.move(page.id, toParent: parentId, at: index)
        return try session.pageResult(page.id)
    }

    static let duplicate: CommandHandler = { session in
        let page = try session.page()
        let copy = try await session.pageTree.duplicate(page.id, now: session.host.now)
        return try session.pageResult(copy.id)
    }

    static let layout: CommandHandler = { session in
        let page = try session.page()
        if let fullWidth = session.string("fullWidth") { try session.pageTree.setFullWidth(page.id, fullWidth == "on") }
        if let smallText = session.string("smallText") { try session.pageTree.setSmallText(page.id, smallText == "on") }
        return try session.pageResult(page.id)
    }

    // MARK: Корзина

    static let trash: CommandHandler = { session in
        let page = try session.page()
        try session.pageTree.moveToTrash(page.id)
        return CommandResult(["id": .string(page.id.controlText), "inTrash": true], text: "«\(page.title)» в корзине")
    }

    static let restore: CommandHandler = { session in
        let page = try session.trashedPage()
        try session.pageTree.restore(page.id)
        return try session.pageResult(page.id)
    }

    static let trashList: CommandHandler = { session in
        let outline = try PageOutline(store: session.host.store)
        let entries = try session.host.store.trashEntries()
        return CommandResult(try session.paged(entries.map(outline.json)), text: "\(entries.count) в корзине")
    }

    static let trashDelete: CommandHandler = { session in
        try requireForce(session)
        let page = try session.trashedPage()
        try session.pageTree.deleteForever(page.id)
        return CommandResult(["id": .string(page.id.controlText), "deleted": true], text: "«\(page.title)» удалена навсегда")
    }

    static let trashEmpty: CommandHandler = { session in
        try requireForce(session)
        let entries = try session.host.store.trashEntries()
        try session.pageTree.emptyTrash()
        return CommandResult(["deleted": .array(entries.map { .string($0.id.controlText) })], text: "Корзина пуста")
    }

    // MARK: Проверки

    @MainActor static func requireForce(_ session: CommandSession) throws(ControlError) {
        guard session.flag("force") else {
            throw ControlError(.forceRequired, "Удаление из корзины не отменяется", hint: "Подтвердите: \(session.spec.example)")
        }
    }

    static func requireSibling(_ after: Page, of parentId: UUID?) throws(ControlError) {
        guard after.parentId == parentId else {
            throw ControlError(.invalidValue, "--after — страница рядом, у того же родителя", hint: "Соседи: mynotion page tree <родитель> --depth 0",
                               details: ["argument": "after"])
        }
    }
}

// MARK: - Содержимое страницы

extension CommandSession {
    /// Изменённая страница целиком (FR-431).
    func pageResult(_ pageId: UUID) throws -> CommandResult {
        guard let (page, json) = try PageQueries.response(for: pageId, in: host.store) else { throw NotesStoreError.pageNotFound(pageId) }
        return CommandResult(["page": json], text: page.title)
    }

    /// Названия и значки страниц по одной выборке на страницу: полное дерево большой базы читается сотни миллисекунд.
    var storedTitles: MentionTitles {
        { [store = host.store] id in (try? store.page(id)).flatMap { $0 }.map { ($0.title, $0.icon) } }
    }

    /// Страница из корзины: без `--include-trashed`.
    func trashedPage() throws -> Page {
        guard let text = string("page") else { throw CommandCatalog.missing(named: "page", in: spec) }
        let page = try pageLocator.resolve(text, includeTrashed: true)
        let outline = try PageOutline(store: host.store)
        guard outline.isInTrash(page) else {
            throw ControlError(.invalidValue, "«\(page.title)» не в корзине", hint: "Корзина: mynotion trash list",
                               details: ["page": .string(page.id.controlText)])
        }
        if page.trashedAt == nil {
            throw ControlError(.invalidValue, "«\(page.title)» в корзине вместе с родителем", hint: "Верните родителя: mynotion trash list",
                               details: ["page": .string(page.id.controlText)])
        }
        return page
    }

    func optionalBlock(_ key: String, inPage pageId: UUID) throws(ControlError) -> Block? {
        guard args[key] != nil else { return nil }
        return try block(key, inPage: pageId)
    }

    /// `markdown` или `blocks` страницы: открытая в окне — как видна там, с незаписанным вводом.
    func content(of pageId: UUID, outline: PageOutline) -> [String: ControlJSON] {
        let titles = outline.titles
        return content(of: pageId, titles: { titles[$0] })
    }

    /// То же с названиями страниц по требованию (для ссылок и упоминаний).
    func content(of pageId: UUID, titles: @escaping MentionTitles) -> [String: ControlJSON] {
        let blocks = host.openDocuments.document(for: pageId)?.allBlocks ?? (try? host.store.pageContent(pageId))?.blocks ?? []
        if string("format") == "json" {
            let byContainer = Dictionary(grouping: blocks, by: \.containerId).mapValues { $0.sorted { $0.sortKey < $1.sortKey } }
            func encode(_ block: Block) -> ControlJSON {
                let children = byContainer[block.id]?.map(encode)
                return BlockJSON.encode(block, titles: titles, children: children)
            }
            return ["blocks": .array((byContainer[nil] ?? []).map(encode))]
        }
        let attachments = host.attachments
        let reader = PageMarkdownReader(pageTitle: titles, attachmentPath: { ref in
            // Файл ещё не скачан — путь будущей копии: по нему запись вернёт то же вложение.
            (attachments.fileURL(for: ref.id)
                ?? attachments.folder.appendingPathComponent(ref.id.uuidString.lowercased()).appendingPathComponent(ref.name)).path
        })
        return ["markdown": .string(reader.markdown(for: blocks))]
    }

    /// Markdown агента → блоки страницы; что перенесено не так — предупреждения со строкой.
    func blocks(fromMarkdown markdown: String, pageId: UUID, existing: [Block], outline: PageOutline) -> [Block] {
        let builder = MarkdownBlocksBuilder(attachments: host.attachments, baseFolder: request.cwd.map { URL(fileURLWithPath: $0, isDirectory: true) },
                                            knownAttachments: existing.flatMap(\.props.attachmentRefs)) { id in
            outline.linkTarget(id, in: pageId)
        }
        let result = builder.blocks(fromMarkdown: markdown, pageId: pageId)
        for warning in result.warnings {
            warn(.markdownUnsupported, warning.message, line: warning.line)
        }
        return result.blocks
    }

    /// `page write` и `--markdown` у `page create`: всё содержимое заново. Ссылки на подстраницы и встроенные базы,
    /// которых в Markdown нет, остаются в конце: Markdown не удаляет страниц.
    func replaceContent(of pageId: UUID, with markdown: String, checkpoint: Bool) async throws {
        let outline = try PageOutline(store: host.store)
        guard let page = outline.page(pageId) else { throw NotesStoreError.pageNotFound(pageId) }
        try outline.requireEditable(page)
        try await editContent(of: pageId, checkpoint: checkpoint) { document in
            var blocks = self.blocks(fromMarkdown: markdown, pageId: pageId, existing: document.blocks, outline: outline)
            let linked = Set(blocks.compactMap(\.linkedPageId))
            let kept = document.blocks.filter { block in
                guard block.containerId == nil, [.pageLink, .database].contains(block.kind), let target = block.linkedPageId,
                      !linked.contains(target), let child = outline.page(target) else { return false }
                return child.parentId == pageId && !outline.isInTrash(child)
            }.sorted { $0.sortKey < $1.sortKey }
            var key = blocks.filter { $0.containerId == nil }.map(\.sortKey).max()
            for var link in kept {
                key = .between(key, nil)
                link.sortKey = key!
                blocks.append(link)
            }
            if blocks.isEmpty {
                blocks = [Block(pageId: pageId, text: .empty, sortKey: .between(nil, nil))]
            }
            let keptIds = Set(kept.map(\.id))
            return BlockChanges(upserts: blocks, removals: document.blocks.map(\.id).filter { !keptIds.contains($0) })
        }
    }

    /// Правка через документ страницы (как в окне) и запись до ответа; ⌘Z в сессии возвращает прежнее.
    func editContent(of pageId: UUID, checkpoint: Bool, _ change: (PageDocument) throws -> BlockChanges) async throws {
        if checkpoint { try await willWrite(pageId) }
        let documents = host.openDocuments
        let document = try documents.open(pageId)
        defer { documents.release(pageId) }
        let changes = try change(document)
        guard !changes.isEmpty else { return }
        let inverse = document.apply(changes)
        Self.registerContentUndo(inverse, in: pageId, documents: documents, undoManager: undoManager)
        touch([pageId])
        guard documents.saveAll() else {
            throw ControlError(.writeFailed, "Не удалось записать страницу на диск", hint: "Повторите команду; место на диске: df -h")
        }
    }

    private static func registerContentUndo(_ changes: BlockChanges, in pageId: UUID, documents: OpenDocuments, undoManager: UndoManager) {
        undoManager.registerUndo(withTarget: documents) { [weak undoManager] documents in
            MainActor.assumeIsolated {
                guard let document = try? documents.open(pageId) else { return }
                let inverse = document.apply(changes)
                documents.saveAll()
                documents.release(pageId)
                if let undoManager { registerContentUndo(inverse, in: pageId, documents: documents, undoManager: undoManager) }
            }
        }
        undoManager.setActionName("Правка агента")
    }
}

// MARK: - Страницы на момент команды

/// Все страницы с корзиной и строками баз: путь, тип, дети. В дереве нет корзины и шаблонов строк (spec US1, сценарий 2).
struct PageOutline {
    private let byId: [UUID: Page]
    private let databases: [UUID: Bool]
    private let childrenByParent: [UUID: [Page]]
    let roots: [Page]
    let titles: [UUID: (title: String, icon: String?)]

    init(store: NotesStore) throws {
        let pages = try store.pageOutline()
        let byId = Dictionary(uniqueKeysWithValues: pages.map { ($0.id, $0) })
        let databases = try store.treeOutline().databases
        self.byId = byId
        self.databases = databases
        titles = byId.mapValues { ($0.title, $0.icon) }
        let visible = pages.filter { page in
            !Self.isInTrash(page, byId) && !(page.isTemplate && page.parentId.map { databases[$0] != nil } == true)
        }
        let order: (Page, Page) -> Bool = { $0.sortKey != $1.sortKey ? $0.sortKey < $1.sortKey : $0.id.uuidString < $1.id.uuidString }
        childrenByParent = Dictionary(grouping: visible.filter { $0.parentId.flatMap { byId[$0] } != nil }) { $0.parentId! }
            .mapValues { $0.sorted(by: order) }
        roots = visible.filter { $0.parentId.flatMap { byId[$0] } == nil }.sorted(by: order)
    }

    func page(_ id: UUID) -> Page? { byId[id] }

    func children(of parentId: UUID?) -> [Page] {
        guard let parentId else { return roots }
        return childrenByParent[parentId] ?? []
    }

    func isInTrash(_ page: Page) -> Bool { Self.isInTrash(page, byId) }

    func kind(of page: Page) -> PageKind {
        if databases[page.id] != nil { return .database }
        if let parentId = page.parentId, databases[parentId] != nil { return .row }
        return .page
    }

    func path(of page: Page) -> [String] {
        var titles: [String] = []
        var current: Page? = page
        while let checked = current, titles.count <= byId.count {
            titles.append(checked.title)
            current = checked.parentId.flatMap { byId[$0] }
        }
        return titles.reversed()
    }

    func json(_ page: Page) -> ControlJSON {
        PageJSON.encode(page, kind: kind(of: page), path: path(of: page), hasChildren: !children(of: page.id).isEmpty,
                        inTrash: isInTrash(page))
    }

    /// Узел `page tree`: дети до глубины `depth` (`nil` — вся ветка).
    func node(_ page: Page, depth: Int?) -> ControlJSON {
        let children = self.children(of: page.id)
        let goesDeeper = depth.map { $0 > 0 } ?? true
        let nested = goesDeeper ? children.map { node($0, depth: depth.map { $0 - 1 }) } : nil
        return PageJSON.treeNode(page, kind: kind(of: page), path: path(of: page), hasChildren: !children.isEmpty, children: nested)
    }

    /// Ссылка `mynotion://page/<id>` строкой: своя встроенная база — блок базы, другая страница — ссылка на неё.
    func linkTarget(_ id: UUID, in pageId: UUID) -> ParsedBlockConverter.LinkTarget? {
        guard let target = byId[id], !isInTrash(target) else { return nil }
        return databases[id] == true && target.parentId == pageId ? .database(id) : .page(id)
    }

    /// Содержимое базы — строки: Markdown в неё не пишется.
    func requireEditable(_ page: Page) throws(ControlError) {
        guard databases[page.id] == nil else {
            throw ControlError(.invalidValue, "«\(page.title)» — база: строки правят команды db", hint: "mynotion db rows \(page.id.controlText)",
                               details: ["page": .string(page.id.controlText)])
        }
    }

    private static func isInTrash(_ page: Page, _ byId: [UUID: Page]) -> Bool {
        var current: Page? = page
        var steps = 0
        while let checked = current, steps <= byId.count {
            if checked.trashedAt != nil { return true }
            current = checked.parentId.flatMap { byId[$0] }
            steps += 1
        }
        return false
    }
}
