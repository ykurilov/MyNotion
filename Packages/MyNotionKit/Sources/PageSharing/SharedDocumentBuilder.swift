import Foundation
import MarkdownExport
import NotesCore
import PageCover
import UniformTypeIdentifiers

/// Снимок для ссылки и всё, что нужно, чтобы его опубликовать.
public struct SharePublication: Sendable {
    public let document: SharedDocument
    public let data: Data
    public let digest: String
    /// Файлы снимка: id → вложение (копию на Mac ищет публикация).
    public let files: [UUID: AttachmentRef]
    /// Страницы и строки баз, правка которых меняет снимок.
    public let watchedIds: Set<UUID>
}

/// Собирает снимок страницы (contracts/share-api.md, «Снимок»). Граница снимка:
/// - сама страница; с `includeSubpages` — вся ветка под ней, без корзины и шаблонов;
/// - без подстраниц — ещё базы, встроенные в страницу блоком базы: таблицей, строки без ссылок;
/// - упоминания, ссылки на страницы, связи баз и ссылки `mynotion://` на страницы вне снимка закрыты: ни названия, ни id;
/// - файлы — только те, на которые ссылаются блоки и обложки снимка.
public struct SharedDocumentBuilder: Sendable {
    let store: NotesStore
    let collapsedBlockIds: @Sendable (UUID) -> Set<UUID>
    let calendar: Calendar

    public init(store: NotesStore, collapsedBlockIds: @escaping @Sendable (UUID) -> Set<UUID>, calendar: Calendar = .current) {
        self.store = store
        self.collapsedBlockIds = collapsedBlockIds
        self.calendar = calendar
    }

    /// `nil` — страницы нет или она в корзине.
    public func build(rootPageId: UUID, includeSubpages: Bool) throws -> SharePublication? {
        guard let root = try store.page(rootPageId), root.trashedAt == nil else { return nil }
        var pages = [root]
        if includeSubpages {
            pages = try branch(of: root)
        }
        var contents: [UUID: PageContent] = [:]
        for page in pages {
            contents[page.id] = try store.pageContent(page.id)
        }
        if !includeSubpages {
            // встроенные базы: страница базы лежит прямо под опубликованной страницей
            let children = try store.childPageContents(of: root.id)
            for block in contents[root.id]?.blocks ?? [] where block.kind == .database {
                guard let id = block.linkedPageId, let child = children[id], child.page.trashedAt == nil, !child.page.isTemplate,
                      !pages.contains(where: { $0.id == id }) else { continue }
                pages.append(child.page)
                contents[id] = child
            }
        }
        let scope = Set(pages.map(\.id))
        var context = Context(scope: scope)
        var shared: [SharedPage] = []
        for page in pages {
            let blocks = contents[page.id]?.blocks ?? []
            shared.append(SharedPage(
                id: page.id.shareKey,
                parentId: page.parentId.flatMap { scope.contains($0) ? $0.shareKey : nil },
                title: page.title,
                icon: page.icon,
                cover: cover(of: page, context: &context),
                fullWidth: page.isFullWidth,
                smallText: page.isSmallText,
                blocks: sharedBlocks(blocks, collapsed: collapsedBlockIds(page.id), context: &context),
                database: try database(page.id, context: &context)))
        }
        let files = context.files.values.sorted { $0.id.uuidString < $1.id.uuidString }.map { ref in
            SharedFile(id: ref.id.shareKey, name: ref.name, mimeType: Self.mimeType(of: ref), byteCount: ref.byteCount)
        }
        let document = SharedDocument(rootPageId: root.id.shareKey, pages: shared, files: files)
        let data = try document.encoded()
        return SharePublication(document: document, data: data, digest: SharedDocument.digest(of: data), files: context.files,
                                watchedIds: scope.union(context.databaseRows))
    }

    /// Ветка по порядку: родитель раньше детей, без корзины и шаблонов (и без всего под ними).
    private func branch(of root: Page) throws -> [Page] {
        let outline = try store.branchOutline(root.id)
        let children = Dictionary(grouping: outline.filter { $0.id != root.id }, by: \.parentId)
        var result: [Page] = []
        var queue = [root]
        var seen: Set<UUID> = []
        while !queue.isEmpty {
            let page = queue.removeFirst()
            guard page.trashedAt == nil, !page.isTemplate, seen.insert(page.id).inserted else { continue }
            result.append(page)
            queue.append(contentsOf: children[page.id] ?? [])
        }
        return result
    }

    private struct Context {
        let scope: Set<UUID>
        var files: [UUID: AttachmentRef] = [:]
        var databaseRows: Set<UUID> = []

        func pageKey(_ id: UUID?) -> String? {
            guard let id, scope.contains(id) else { return nil }
            return id.shareKey
        }

        mutating func file(_ ref: AttachmentRef?) -> String? {
            guard let ref else { return nil }
            files[ref.id] = ref
            return ref.id.shareKey
        }
    }

    private func cover(of page: Page, context: inout Context) -> SharedCover? {
        guard let cover = page.cover else { return nil }
        switch cover.source {
        case .file(let ref):
            return SharedCover(file: context.file(ref), offset: cover.offset)
        case .gallery(let id):
            guard let item = CoverGallery.item(id) else { return nil }
            let (side, colors) = item.webColors
            return SharedCover(colors: colors, side: side, offset: cover.offset)
        case .unknown:
            return nil
        }
    }

    // MARK: Блоки

    private func sharedBlocks(_ blocks: [Block], collapsed: Set<UUID>, context: inout Context) -> [SharedBlock] {
        // отступ для показа считается внутри каждого контейнера: у колонки и ячейки свой поток
        var indents: [UUID: Int] = [:]
        for flow in Dictionary(grouping: blocks, by: \.containerId).values {
            for (block, indent) in zip(flow, BlockNesting.displayIndents(flow)) { indents[block.id] = indent }
        }
        return blocks.map { block in
            let props = props(of: block, context: &context)
            return SharedBlock(
                id: block.id.shareKey,
                kind: block.kind.rawValue,
                indent: indents[block.id] ?? 0,
                container: block.containerId?.shareKey,
                text: text(block.kind == .code || block.kind == .equation ? InlineText(block.text.string) : block.text, context: context),
                checked: block.kind == .checkbox && block.isChecked ? true : nil,
                collapsed: collapsed.contains(block.id) ? true : nil,
                color: block.color.isNone ? nil : SharedColor(text: block.color.text?.rawValue, background: block.color.background?.rawValue),
                props: props.isEmpty ? nil : props,
                page: block.kind.linksPage ? SharedPageRef(id: context.pageKey(block.linkedPageId)) : nil)
        }
    }

    private func props(of block: Block, context: inout Context) -> SharedBlockProps {
        let source = block.props
        var props = SharedBlockProps()
        switch block.kind {
        case .callout:
            props.icon = source.icon
        case .code:
            props.language = source.language
        case .image:
            props.file = context.file(source.attachment)
            props.width = source.width
            props.pixelSize = source.pixelSize.map { [Double($0.width), Double($0.height)] }
        case .file:
            props.file = context.file(source.attachment)
        case .video:
            props.videoSource = source.videoSource?.rawValue
            props.width = source.width
            if source.videoSource == .file { props.file = context.file(source.attachment) } else { props.url = source.url?.absoluteString }
            props.poster = context.file(source.poster)
        case .bookmark:
            props.url = source.url?.absoluteString
            props.title = source.title
            props.description = source.description
            props.image = context.file(source.image)
            props.iconFile = context.file(source.iconAttachment)
        case .table:
            props.hasHeaderRow = source.hasHeaderRow
            props.hasHeaderColumn = source.hasHeaderColumn
        case .tableColumn:
            props.width = source.width
        case .tableCell:
            props.columnId = source.columnId?.shareKey
        case .column:
            props.widthRatio = source.widthRatio
        default:
            break
        }
        return props
    }

    private func text(_ text: InlineText, context: Context) -> SharedText {
        let runs = text.runs.compactMap { run -> SharedRun? in
            var shared = SharedRun(start: run.start, length: run.length, style: "")
            switch run.style {
            case .bold: shared.style = "bold"
            case .italic: shared.style = "italic"
            case .strikethrough: shared.style = "strikethrough"
            case .code: shared.style = "code"
            case .underline: shared.style = "underline"
            case .link(let url):
                if url.scheme == "mynotion" {
                    // ссылка на страницу: внутрь снимка — оставить, наружу — убрать вместе с id
                    guard let id = UUID(uuidString: url.lastPathComponent), context.scope.contains(id) else { return nil }
                    shared.url = "mynotion://page/\(id.shareKey)"
                } else {
                    shared.url = url.absoluteString
                }
                shared.style = "link"
            case .textColor(let color):
                shared.style = "textColor"
                shared.color = color.rawValue
            case .backgroundColor(let color):
                shared.style = "backgroundColor"
                shared.color = color.rawValue
            case .mention(let pageId):
                shared.style = "mention"
                shared.pageId = context.pageKey(pageId)
            case .date(let date):
                shared.style = "date"
                shared.text = "@" + date.absoluteText(calendar: calendar)
            case .equation(let latex):
                shared.style = "equation"
                shared.latex = latex
            }
            return shared
        }
        return SharedText(string: text.string, runs: runs)
    }

    // MARK: Базы

    private func database(_ pageId: UUID, context: inout Context) throws -> SharedDatabase? {
        let scope = context.scope
        guard let table = try DatabaseTableText.read(pageId, from: store, relationTitle: { target, title in
            scope.contains(target) ? title : nil
        }) else { return nil }
        context.databaseRows.formUnion(table.rows.map(\.page.id))
        return SharedDatabase(columns: table.columns, rows: table.rows.map { row in
            SharedDatabase.Row(pageId: context.pageKey(row.page.id), title: row.page.title, icon: row.page.icon, cells: row.cells)
        })
    }

    // MARK: Файлы

    /// Тип файла для браузера: `contentType` вложения — тип Apple (`public.png`), а не MIME.
    static func mimeType(of ref: AttachmentRef) -> String {
        if ref.contentType.contains("/") { return ref.contentType }
        return UTType(ref.contentType)?.preferredMIMEType
            ?? UTType(filenameExtension: (ref.name as NSString).pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
    }
}
