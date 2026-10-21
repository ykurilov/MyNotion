import Foundation
import LinkPreview
import NotesCore
import UniformTypeIdentifiers

/// Ход импорта: сначала чтение страниц выгрузки, потом запись в базу.
public struct NotionImportProgress: Sendable, Equatable {
    public enum Phase: Sendable, Equatable { case reading, writing }
    public var phase: Phase
    public var done: Int
    public var total: Int

    public init(phase: Phase, done: Int, total: Int) {
        self.phase = phase
        self.done = done
        self.total = total
    }
}

/// Страница, где что-то упрощено, и что именно: «таблица ×2», «цитата».
public struct SimplifiedPage: Sendable, Hashable, Codable {
    public var pageTitle: String
    public var items: [String]

    public init(pageTitle: String, items: [String]) {
        self.pageTitle = pageTitle
        self.items = items
    }
}

/// Отчёт после импорта (FR-026): сколько перенесено, что упрощено и чего выгрузка не содержит вовсе.
public struct NotionImportReport: Sendable, Equatable {
    /// Цветов и колонок в выгрузке Notion «Markdown & CSV» нет: отчёт называет потерю всегда (research R14, решение Юрия).
    public static let markdownLossNotice = "Цвета и колонки Notion в Markdown не выгружает — они не перенесены"
    /// Обложек в выгрузке Notion «Markdown & CSV» нет (research R13); своя выгрузка MyNotion их возвращает.
    public static let coverLossNotice = "Обложки страниц Notion в выгрузку не попадают"

    public var rootPageId: UUID
    public var rootTitle: String
    public var pageCount: Int
    public var blockCount: Int
    public var simplified: [SimplifiedPage]
    /// Потери самого формата выгрузки — не по страницам.
    public var notices: [String]
    /// Базы (004): по базе — строки, угаданные типы, что перенесено не целиком.
    public var databases: [DatabaseImportSummary]

    public init(rootPageId: UUID, rootTitle: String, pageCount: Int, blockCount: Int, simplified: [SimplifiedPage],
                notices: [String] = [Self.markdownLossNotice, Self.coverLossNotice], databases: [DatabaseImportSummary] = []) {
        self.rootPageId = rootPageId
        self.rootTitle = rootTitle
        self.pageCount = pageCount
        self.blockCount = blockCount
        self.simplified = simplified
        self.notices = notices
        self.databases = databases
    }
}

/// Запись журнала импортов (`import_run`, data-model.md «ImportRun»).
public struct NotionImportRun: Sendable, Equatable {
    public enum Status: String, Sendable { case running, finished, failed }
    public var id: UUID
    public var sourceFingerprint: String
    public var startedAt: Date
    public var finishedAt: Date?
    public var rootPageId: UUID?
    public var importedPages: Int
    public var simplifiedItems: [SimplifiedPage]
    public var status: Status

    public init(id: UUID, sourceFingerprint: String, startedAt: Date, finishedAt: Date?, rootPageId: UUID?, importedPages: Int,
                simplifiedItems: [SimplifiedPage], status: Status) {
        self.id = id
        self.sourceFingerprint = sourceFingerprint
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.rootPageId = rootPageId
        self.importedPages = importedPages
        self.simplifiedItems = simplifiedItems
        self.status = status
    }
}

/// Куда импорт копирует картинки и файлы выгрузки: хранилище вложений приложения (`Attachments`).
public protocol NotionAttachmentImporting: Sendable {
    /// Скопировать файл; больше 100 МБ или не читается — ошибка, блок станет абзацем «[файл: имя]».
    func importFile(at url: URL) throws -> AttachmentRef
}

/// Импорт выгрузки Notion в новую ветку «Импорт из Notion — <дата>» (FR-025…FR-027, T089).
///
/// Сначала вся выгрузка читается и разбирается в память, потом пишется в базу короткими транзакциями по несколько
/// страниц: правка открытой страницы (автосохранение на главном потоке) ждёт не дольше одной такой транзакции,
/// и окно не замирает. Ветка и запись журнала `import_run` со статусом running появляются первой транзакцией.
/// При ошибке или отмене ветка стирается целиком, журнал — failed. Если приложение упало посреди импорта,
/// ветку стирает `rollBackInterruptedImports()` при следующем запуске: недоделанная ветка не остаётся.
/// Существующие записи импорт не меняет: он только добавляет новые страницы.
public struct NotionImporter: Sendable {
    private let store: NotesStore
    private let now: @Sendable () -> Date
    /// Хранилище вложений; без него картинки и файлы — абзацы «[файл: имя]», как в 001.
    private let attachments: (any NotionAttachmentImporting)?
    /// Откатывать ли ветку при ошибке; в тестах выключается, чтобы изобразить падение приложения посреди импорта.
    var rollsBackOnFailure = true
    /// Сколько блоков пишется одной транзакцией: короткие транзакции не держат базу, и правка открытой страницы
    /// не ждёт конца импорта. Страница целиком всегда в одной транзакции.
    var maxBlocksPerTransaction = 1_000
    /// Сколько связей строк баз пишется одной транзакцией.
    var maxLinksPerTransaction = 2_000
    /// Для тестов: упасть после стольких записанных строк баз (откат ветки с базами).
    var failAfterDatabaseRows: Int?

    public init(store: NotesStore, now: @escaping @Sendable () -> Date = { Date() }, attachments: (any NotionAttachmentImporting)? = nil) {
        self.store = store
        self.now = now
        self.attachments = attachments
    }

    /// Удачный импорт той же выгрузки, если он уже был (FR-027): предупредить до начала.
    public func previousImport(withFingerprint fingerprint: String) throws -> NotionImportRun? {
        try ImportRunLog(store: store).latestFinished(fingerprint: fingerprint)
    }

    /// Весь журнал импортов, новые первыми.
    public func runs() throws -> [NotionImportRun] {
        try ImportRunLog(store: store).all()
    }

    public func importExport(_ export: PreparedNotionExport,
                             progress: (@Sendable (NotionImportProgress) -> Void)? = nil) throws -> NotionImportReport {
        try Task.checkCancellation()
        var plan = try NotionExportReader().read(export.contentRoot) { done, total in
            progress?(NotionImportProgress(phase: .reading, done: done, total: total))
        }
        let databases = try NotionDatabaseReader().read(&plan)
        try copyAttachments(in: &plan, root: export.contentRoot)
        let log = ImportRunLog(store: store)
        let startedAt = now()
        let rootTitle = "Импорт из Notion — " + Self.dateTitle(startedAt)
        let pageIds = plan.pages.map(\.id)
        let rootId = UUID.timeOrdered()
        let runId = UUID.timeOrdered()

        try Task.checkCancellation()
        do {
            try store.write { transaction in
                let lastRootKey = try transaction.allPages().filter { $0.parentId == nil }.map(\.sortKey).max()
                try transaction.insertPage(Page(id: rootId, title: rootTitle, sortKey: .between(lastRootKey, nil),
                                                createdAt: startedAt, updatedAt: startedAt))
                var sortKey: FractionalSortKey?
                for child in plan.roots {
                    sortKey = .between(sortKey, nil)
                    try transaction.insertBlock(Block(pageId: rootId, kind: .pageLink, linkedPageId: pageIds[child], sortKey: sortKey!))
                }
                try log.insertRunning(id: runId, fingerprint: export.fingerprint, startedAt: startedAt, rootPageId: rootId, in: transaction)
            }
        } catch {
            throw Self.importError(error)
        }

        do {
            let written = try writePages(of: plan, databases: databases, ids: pageIds, rootId: rootId, startedAt: startedAt,
                                         progress: progress)
            try writeDatabaseLinks(databases, ids: pageIds)
            let simplified = Self.simplifiedPages(in: plan)
            try store.write { transaction in
                try log.finish(id: runId, at: now(), importedPages: plan.pages.count, simplified: simplified, in: transaction)
            }
            var notices = [NotionImportReport.markdownLossNotice, NotionImportReport.coverLossNotice]
            if databases.values.contains(where: \.isFromNotion) { notices += NotionDatabaseReader.notionNotices }
            let summaries = Self.databaseOrder(in: plan).compactMap { databases[$0]?.summary }
            return NotionImportReport(rootPageId: rootId, rootTitle: rootTitle, pageCount: plan.pages.count,
                                      blockCount: written, simplified: simplified, notices: notices, databases: summaries)
        } catch {
            if rollsBackOnFailure {
                // Не откатилось (например, диск всё ещё полон) — журнал остаётся running, и ветку сотрёт следующий запуск.
                if (try? eraseBranch(rootId)) != nil {
                    try? store.write { try log.markFailed(id: runId, at: now(), in: $0) }
                }
            }
            throw Self.importError(error)
        }
    }

    /// Импорты, оставшиеся «в работе» после падения приложения: стереть их ветки, пометить неудачными. Сколько откачено.
    /// Вызывается при запуске, до первого импорта.
    @discardableResult
    public func rollBackInterruptedImports() throws -> Int {
        let log = ImportRunLog(store: store)
        let interrupted = try log.all().filter { $0.status == .running }
        for run in interrupted {
            if let rootPageId = run.rootPageId { try eraseBranch(rootPageId) }
            try store.write { try log.markFailed(id: run.id, at: now(), in: $0) }
        }
        return interrupted.count
    }

    // MARK: Файлы

    /// Картинки и файлы выгрузки — копиями во вложения (contracts/markdown-and-notion.md). Файла нет, он больше 100 МБ,
    /// лежит вне папки выгрузки `root` или хранилища нет — абзац «[файл: имя]», как в 001, и строка в отчёте.
    private func copyAttachments(in plan: inout NotionExportPlan, root: URL) throws {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        for index in plan.pages.indices {
            let folder = plan.pages[index].file.deletingLastPathComponent()
            var missing = 0
            func copy(_ path: String, imageOnly: Bool = false) -> (URL, AttachmentRef)? {
                // Путь из текста страницы: `..` и ярлыки не выводят за папку выгрузки.
                let url = path.split(separator: "/").reduce(folder) { $0.appendingPathComponent(String($1)) }
                    .standardizedFileURL.resolvingSymlinksInPath()
                guard url.path.hasPrefix(rootPath + "/") else { return nil }
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey, .isRegularFileKey])
                guard values?.isRegularFile == true else { return nil }
                if imageOnly, values?.contentType?.conforms(to: .image) != true { return nil }
                let size = values?.fileSize
                guard let size, size <= AttachmentRef.maximumByteCount, let ref = try? attachments?.importFile(at: url) else { return nil }
                return (url, ref)
            }
            func attach(_ blocks: inout [ParsedBlock]) throws {
                for position in blocks.indices {
                    try attach(&blocks[position].contained)
                    for (file, path) in blocks[position].decorationPaths {
                        try Task.checkCancellation()
                        guard let (_, ref) = copy(path) else { continue }
                        switch file {
                        case .poster: blocks[position].props.poster = ref
                        case .image: blocks[position].props.image = ref
                        case .icon: blocks[position].props.iconAttachment = ref
                        }
                    }
                    blocks[position].decorationPaths = [:]
                    guard let path = blocks[position].attachmentPath else { continue }
                    try Task.checkCancellation()
                    blocks[position].attachmentPath = nil
                    if let (url, ref) = copy(path) {
                        blocks[position].props.attachment = ref
                        // Размер картинки — из файла: вид знает высоту блока до загрузки картинки (как при вставке).
                        if blocks[position].kind == .image, let size = PixelSize(ofImageAt: url) { blocks[position].props.pixelSize = size }
                    } else {
                        let name = (path as NSString).lastPathComponent
                        blocks[position] = ParsedBlock(kind: .paragraph, text: InlineText("[файл: \(name)]"),
                                                       indent: blocks[position].indent)
                        missing += 1
                    }
                }
            }
            try attach(&plan.pages[index].blocks)
            if case .file(let name)? = plan.pages[index].cover?.source {
                let stem = plan.pages[index].file.deletingPathExtension().lastPathComponent
                // Обложка — картинка в папке страницы. Картинки нет, это не картинка или она не копируется — страница
                // без обложки, как у импорта Notion.
                let isFileName = !name.contains("/") && name != "." && name != ".."
                plan.pages[index].coverFile = isFileName ? copy(stem + "/" + name, imageOnly: true)?.1 : nil
            }
            if missing > 0 { plan.pages[index].simplifications[.file, default: 0] += missing }
        }
    }

    // MARK: Запись

    /// Страницы в порядке дерева (родитель раньше подстраниц), пачками не больше `maxBlocksPerTransaction` блоков.
    private func writePages(of plan: NotionExportPlan, databases: [Int: PlannedDatabase], ids: [UUID], rootId: UUID, startedAt: Date,
                            progress: (@Sendable (NotionImportProgress) -> Void)?) throws -> Int {
        var rowsByPage: [Int: PlannedRow] = [:]
        for database in databases.values { for row in database.rows { rowsByPage[row.pageIndex] = row } }
        var order: [Int] = []
        func visit(_ indices: [Int]) {
            for index in indices {
                order.append(index)
                visit(plan.pages[index].children)
            }
        }
        visit(plan.roots)

        // Ключи порядка среди соседей: по порядку детей у родителя.
        var sortKeys: [Int: FractionalSortKey] = [:]
        for siblings in [plan.roots] + plan.pages.map(\.children) {
            var key: FractionalSortKey?
            for index in siblings {
                key = .between(key, nil)
                sortKeys[index] = plan.pages[index].sortKey ?? key
            }
        }

        var written = 0
        var writtenRows = 0
        var position = 0
        while position < order.count {
            try Task.checkCancellation()
            var batch: [(Int, [Block])] = []
            var batchWeight = 0
            while position < order.count {
                let index = order[position]
                let blocks = Self.blocks(for: index, in: plan, databases: databases, ids: ids)
                // Ячейки строки весят как блоки: транзакция с базой не длиннее обычной.
                let weight = blocks.count + (rowsByPage[index]?.cells.count ?? 0)
                if !batch.isEmpty, batchWeight + weight > maxBlocksPerTransaction { break }
                batch.append((index, blocks))
                batchWeight += weight
                position += 1
            }
            try store.write { transaction in
                for (index, blocks) in batch {
                    let planned = plan.pages[index]
                    let row = rowsByPage[index]
                    // Ячейки — раньше страницы: запись ячейки сдвигает «изменено» строки, а оно — из выгрузки.
                    for cell in row?.cells ?? [] { try transaction.setCell(rowId: ids[index], propertyId: cell.propertyId, value: cell.value) }
                    try transaction.insertPage(Page(id: ids[index], title: planned.title, icon: planned.icon,
                                                    parentId: planned.parent.map { ids[$0] } ?? rootId,
                                                    sortKey: sortKeys[index]!, createdAt: row?.createdAt ?? startedAt,
                                                    updatedAt: row?.updatedAt ?? row?.createdAt ?? startedAt,
                                                    cover: Self.cover(of: planned), isTemplate: row?.isTemplate ?? false))
                    if let database = databases[index] { try Self.writeSchema(of: database, in: transaction) }
                    for block in blocks { try transaction.insertBlock(block) }
                    if row != nil {
                        writtenRows += 1
                        if let limit = failAfterDatabaseRows, writtenRows >= limit { throw NotionImportError.cannotWrite("проверка отката") }
                    }
                }
            }
            written += batch.reduce(0) { $0 + $1.1.count }
            progress?(NotionImportProgress(phase: .writing, done: position, total: order.count))
        }
        return written
    }

    // MARK: Базы

    /// Схема базы — в той же транзакции, что её страница: база, свойства, варианты, виды.
    private static func writeSchema(of database: PlannedDatabase, in transaction: NotesTransaction) throws {
        var schema = database.schema
        // Шаблон по умолчанию — когда шаблоны уже записаны (`writeDatabaseLinks`).
        schema.defaultTemplateId = nil
        try transaction.saveDatabase(schema)
        for property in database.properties { try transaction.saveProperty(property) }
        for option in database.options { try transaction.saveOption(option) }
        for view in database.views { try transaction.saveView(view) }
    }

    /// Второй проход, когда все строки записаны: связи, ручной порядок строк в видах, шаблон по умолчанию.
    /// Связь пары хранится у свойства с меньшим id (data-model.md, `db_relation_link`): сторона с большим id пишет
    /// свои связи, только если у меньшей их в плане нет (пара ведёт на базу вне выгрузки).
    private func writeDatabaseLinks(_ databases: [Int: PlannedDatabase], ids: [UUID]) throws {
        let planned = Set(databases.values.flatMap { database in
            database.rows.flatMap { $0.relations.map(\.propertyId) }
        })
        let properties = Dictionary(databases.values.flatMap(\.properties).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Своя выгрузка хранит записи связей с ключами порядка: свойства её баз берут связи только оттуда.
        let withLinks = databases.values.filter { $0.links != nil }
        let coveredByLinks = Set(withLinks.flatMap { $0.properties.map(\.id) })
        var links: [RelationLink] = withLinks.flatMap { $0.links ?? [] }
        for database in databases.values.sorted(by: { $0.pageIndex < $1.pageIndex }) {
            for row in database.rows {
                let rowId = ids[row.pageIndex]
                for (propertyId, targets) in row.relations {
                    let paired = properties[propertyId]?.config["pairedPropertyId"]?.string.flatMap(UUID.init(uuidString:))
                    let storing = paired.flatMap { $0 < propertyId ? $0 : nil } ?? propertyId
                    if coveredByLinks.contains(storing) { continue }
                    if let paired, paired < propertyId {
                        guard !planned.contains(paired) else { continue }
                        for target in targets {
                            links.append(RelationLink(propertyId: paired, rowId: target, targetRowId: rowId, sortKey: .between(nil, nil)))
                        }
                        continue
                    }
                    var key: FractionalSortKey?
                    for target in targets {
                        key = .between(key, nil)
                        links.append(RelationLink(propertyId: propertyId, rowId: rowId, targetRowId: target, sortKey: key!))
                    }
                }
            }
        }
        var position = 0
        while position < links.count {
            try Task.checkCancellation()
            let batch = links[position..<min(position + maxLinksPerTransaction, links.count)]
            try store.write { transaction in
                for link in batch where try transaction.page(link.targetRowId) != nil && transaction.page(link.rowId) != nil {
                    try transaction.saveRelationLink(link)
                }
            }
            position += batch.count
        }
        let finishing = databases.values.filter { !$0.rowOrders.isEmpty || $0.schema.defaultTemplateId != nil }
        guard !finishing.isEmpty else { return }
        try store.write { transaction in
            for database in finishing {
                for order in database.rowOrders { try transaction.setRowOrder(viewId: order.viewId, rowId: order.rowId, sortKey: order.sortKey) }
                if let template = database.schema.defaultTemplateId, try transaction.page(template) != nil {
                    try transaction.saveDatabase(database.schema)
                }
            }
        }
    }

    /// Базы в порядке дерева выгрузки — для отчёта.
    private static func databaseOrder(in plan: NotionExportPlan) -> [Int] {
        var result: [Int] = []
        func visit(_ indices: [Int]) {
            for index in indices {
                if plan.pages[index].isTable { result.append(index) }
                visit(plan.pages[index].children)
            }
        }
        visit(plan.roots)
        return result
    }

    /// Обложка страницы из комментария своей выгрузки; картинка — только скопированная.
    private static func cover(of page: PlannedPage) -> PageCover? {
        switch page.cover?.source {
        case .gallery(let id)?: PageCover(source: .gallery(id), offset: page.cover!.offset)
        case .file?: page.coverFile.map { PageCover(source: .file($0), offset: page.cover!.offset) }
        case nil: nil
        }
    }

    /// Блоки страницы для базы: ссылки на найденные страницы — pageLink, на ненайденные — абзац с названием;
    /// подстраницы без ссылки в тексте получают ссылку в конце (подстраница и ссылка на неё — пара, data-model.md).
    private static func blocks(for index: Int, in plan: NotionExportPlan, databases: [Int: PlannedDatabase], ids: [UUID]) -> [Block] {
        let page = plan.pages[index]
        let pageId = ids[index]
        // У страницы-базы своих блоков нет: её содержимое — строки (data-model.md).
        if databases[index] != nil { return [] }
        var result: [Block] = []
        var sortKey: FractionalSortKey?
        var linkedChildren: Set<Int> = []
        func append(_ kind: BlockKind, _ text: InlineText = .empty, indent: Int = 0, checked: Bool = false, link: UUID? = nil) {
            sortKey = .between(sortKey, nil)
            // Заголовок бывает вложен в переключатель, выноску, цитату (research R1).
            result.append(Block(pageId: pageId, kind: kind, text: text, indent: indent,
                                isChecked: kind == .checkbox && checked, linkedPageId: link, sortKey: sortKey!))
        }
        /// Блок 002 с цветом, свойствами и потоками внутри (колонки, таблица).
        func appendRich(_ parsed: ParsedBlock) {
            sortKey = .between(sortKey, nil)
            let block = Block(id: parsed.id ?? .timeOrdered(), pageId: pageId, kind: parsed.kind, text: parsed.text, indent: parsed.indent,
                              isChecked: parsed.kind == .checkbox && parsed.isChecked, sortKey: sortKey!,
                              color: parsed.color, props: parsed.props)
            result.append(block)
            func appendContained(_ children: [ParsedBlock], in containerId: UUID) {
                var key: FractionalSortKey?
                for child in children {
                    key = .between(key, nil)
                    // Упоминания в ячейках таблицы и блоках колонок — на страницы выгрузки, как в потоке страницы.
                    let text = child.mentions.isEmpty ? child.text : resolvingMentions(in: child.text, mentions: child.mentions) { path in
                        plan.page(atPath: path, from: index).map { ids[$0] }
                    }
                    let inner = Block(id: child.id ?? .timeOrdered(), pageId: pageId, kind: child.kind, text: text, indent: child.indent,
                                      isChecked: child.kind == .checkbox && child.isChecked, sortKey: key!, containerId: containerId,
                                      color: child.color, props: child.props)
                    result.append(inner)
                    appendContained(child.contained, in: inner.id)
                }
            }
            appendContained(parsed.contained, in: block.id)
        }
        for var block in page.blocks {
            if !block.mentions.isEmpty {
                block.text = resolvingMentions(in: block.text, mentions: block.mentions) { path in
                    plan.page(atPath: path, from: index).map { ids[$0] }
                }
            }
            if let target = NotionExportReader.linkedPage(block, from: index, in: plan) {
                if page.children.contains(target) { linkedChildren.insert(target) }
                // Встроенная база — блок `database` на месте ссылки на её CSV.
                let isInline = databases[target]?.schema.isInline == true && plan.pages[target].parent == index
                append(isInline ? .database : .pageLink, link: ids[target])
            } else if block.kind == .pageLink {
                append(.paragraph, block.text)
            } else if let url = block.standaloneURL, block.kind == .paragraph, ["http", "https"].contains(url.scheme?.lowercased()) {
                appendRich(Self.linkCard(for: url, text: block.text, indent: block.indent))
            } else if !block.color.isNone || !block.props.isEmpty || !block.contained.isEmpty {
                appendRich(block)
            } else {
                append(block.kind, block.text, indent: block.indent, checked: block.isChecked)
            }
        }
        for child in page.children where !linkedChildren.contains(child) {
            append(.pageLink, link: ids[child])
        }
        if result.isEmpty { append(.paragraph) }
        return result
    }

    /// Ссылка на своей строке, не на страницу выгрузки: YouTube и Vimeo — видео, прочее — закладка с адресом
    /// (данные карточки не запрашиваются, «Обновить» — по желанию). Текст ссылки, отличный от адреса, — заголовок.
    static func linkCard(for url: URL, text: InlineText, indent: Int) -> ParsedBlock {
        var props = BlockProps()
        props.url = url
        if let link = VideoLink(url: url) {
            props.videoSource = link.sourceName == "vimeo" ? .vimeo : .youtube
            return ParsedBlock(kind: .video, indent: indent, props: props)
        }
        let title = text.string.trimmingCharacters(in: .whitespaces)
        if !title.isEmpty, title != url.absoluteString { props.title = title }
        return ParsedBlock(kind: .bookmark, indent: indent, props: props)
    }

    /// Упоминания с временным id — на страницы выгрузки; страницы нет — название ссылки простым текстом.
    static func resolvingMentions(in text: InlineText, mentions: [NotionPageMention], pageId: (String) -> UUID?) -> InlineText {
        let byPlaceholder = Dictionary(mentions.map { ($0.placeholder, $0) }) { first, _ in first }
        var units = Array(text.string.utf16)
        var runs = text.runs
        for run in text.runs.sorted(by: { $0.start > $1.start }) {
            guard case .mention(let placeholder) = run.style, let mention = byPlaceholder[placeholder],
                  let position = runs.firstIndex(of: run) else { continue }
            if let target = pageId(mention.path) {
                runs[position].style = .mention(target)
                continue
            }
            // Название вместо знака: оформление правее сдвигается на разницу длин.
            runs.remove(at: position)
            let title = Array(mention.title.utf16)
            units.replaceSubrange(run.start..<run.start + 1, with: title)
            let shift = title.count - 1
            runs = runs.map { other in
                var other = other
                if other.start > run.start { other.start += shift } else if other.start + other.length > run.start { other.length += shift }
                return other
            }
        }
        return InlineText(String(decoding: units, as: UTF16.self), runs: runs).normalized()
    }

    /// Стереть ветку импорта: корень и все страницы под ним, включая убранные в корзину.
    private func eraseBranch(_ rootId: UUID) throws {
        try store.write { transaction in
            let pages = try transaction.allPages()
            let childrenByParent = Dictionary(grouping: pages.filter { $0.parentId != nil }, by: { $0.parentId! })
            var branch: [UUID] = []
            var queue = pages.contains { $0.id == rootId } ? [rootId] : []
            while let id = queue.popLast() {
                branch.append(id)
                queue += childrenByParent[id]?.map(\.id) ?? []
            }
            for id in branch.reversed() { try transaction.erasePage(id) }
        }
    }

    // MARK: Отчёт

    private static func simplifiedPages(in plan: NotionExportPlan) -> [SimplifiedPage] {
        var result: [SimplifiedPage] = []
        func visit(_ indices: [Int]) {
            for index in indices {
                let page = plan.pages[index]
                var items = NotionSimplification.allCases.compactMap { kind -> String? in
                    guard let count = page.simplifications[kind], count > 0 else { return nil }
                    return kind.title(count: count)
                }
                if !page.unknownCodeLanguages.isEmpty { items.append(NotionSimplification.unknownCodeLanguagesTitle(page.unknownCodeLanguages)) }
                if !items.isEmpty { result.append(SimplifiedPage(pageTitle: page.title.isEmpty ? Page.untitledTitle : page.title, items: items)) }
                visit(page.children)
            }
        }
        visit(plan.roots)
        return result
    }

    /// «18 октября 2026».
    static func dateTitle(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "d MMMM yyyy"
        return formatter.string(from: date)
    }

    private static func importError(_ error: any Error) -> any Error {
        switch error {
        case is CancellationError, is NotionImportError: error
        default: NotionImportError.cannotWrite(error.localizedDescription)
        }
    }
}
