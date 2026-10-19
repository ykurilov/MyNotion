import Foundation
import NotesCore

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

/// Отчёт после импорта (FR-026): сколько перенесено и что упрощено.
public struct NotionImportReport: Sendable, Equatable {
    public var rootPageId: UUID
    public var rootTitle: String
    public var pageCount: Int
    public var blockCount: Int
    public var simplified: [SimplifiedPage]

    public init(rootPageId: UUID, rootTitle: String, pageCount: Int, blockCount: Int, simplified: [SimplifiedPage]) {
        self.rootPageId = rootPageId
        self.rootTitle = rootTitle
        self.pageCount = pageCount
        self.blockCount = blockCount
        self.simplified = simplified
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
    /// Откатывать ли ветку при ошибке; в тестах выключается, чтобы изобразить падение приложения посреди импорта.
    var rollsBackOnFailure = true
    /// Сколько блоков пишется одной транзакцией: короткие транзакции не держат базу, и правка открытой страницы
    /// не ждёт конца импорта. Страница целиком всегда в одной транзакции.
    var maxBlocksPerTransaction = 1_000

    public init(store: NotesStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.now = now
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
        let plan = try NotionExportReader().read(export.contentRoot) { done, total in
            progress?(NotionImportProgress(phase: .reading, done: done, total: total))
        }
        let log = ImportRunLog(store: store)
        let startedAt = now()
        let rootTitle = "Импорт из Notion — " + Self.dateTitle(startedAt)
        let pageIds = plan.pages.map { _ in UUID.timeOrdered() }
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
            let written = try writePages(of: plan, ids: pageIds, rootId: rootId, startedAt: startedAt, progress: progress)
            let simplified = Self.simplifiedPages(in: plan)
            try store.write { transaction in
                try log.finish(id: runId, at: now(), importedPages: plan.pages.count, simplified: simplified, in: transaction)
            }
            return NotionImportReport(rootPageId: rootId, rootTitle: rootTitle, pageCount: plan.pages.count,
                                      blockCount: written, simplified: simplified)
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

    // MARK: Запись

    /// Страницы в порядке дерева (родитель раньше подстраниц), пачками не больше `maxBlocksPerTransaction` блоков.
    private func writePages(of plan: NotionExportPlan, ids: [UUID], rootId: UUID, startedAt: Date,
                            progress: (@Sendable (NotionImportProgress) -> Void)?) throws -> Int {
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
                sortKeys[index] = key
            }
        }

        var written = 0
        var position = 0
        while position < order.count {
            try Task.checkCancellation()
            var batch: [(Int, [Block])] = []
            var batchBlocks = 0
            while position < order.count {
                let index = order[position]
                let blocks = Self.blocks(for: index, in: plan, ids: ids)
                if !batch.isEmpty, batchBlocks + blocks.count > maxBlocksPerTransaction { break }
                batch.append((index, blocks))
                batchBlocks += blocks.count
                position += 1
            }
            try store.write { transaction in
                for (index, blocks) in batch {
                    let planned = plan.pages[index]
                    try transaction.insertPage(Page(id: ids[index], title: planned.title, icon: planned.icon,
                                                    parentId: planned.parent.map { ids[$0] } ?? rootId,
                                                    sortKey: sortKeys[index]!, createdAt: startedAt, updatedAt: startedAt))
                    for block in blocks { try transaction.insertBlock(block) }
                }
            }
            written += batchBlocks
            progress?(NotionImportProgress(phase: .writing, done: position, total: order.count))
        }
        return written
    }

    /// Блоки страницы для базы: ссылки на найденные страницы — pageLink, на ненайденные — абзац с названием;
    /// подстраницы без ссылки в тексте получают ссылку в конце (подстраница и ссылка на неё — пара, data-model.md).
    private static func blocks(for index: Int, in plan: NotionExportPlan, ids: [UUID]) -> [Block] {
        let page = plan.pages[index]
        let pageId = ids[index]
        var result: [Block] = []
        var sortKey: FractionalSortKey?
        var linkedChildren: Set<Int> = []
        func append(_ kind: BlockKind, _ text: InlineText = .empty, indent: Int = 0, checked: Bool = false, link: UUID? = nil) {
            sortKey = .between(sortKey, nil)
            result.append(Block(pageId: pageId, kind: kind, text: text, indent: kind.isHeading ? 0 : indent,
                                isChecked: kind == .checkbox && checked, linkedPageId: link, sortKey: sortKey!))
        }
        /// Блок 002 с цветом, свойствами и потоками внутри (колонки, таблица).
        func appendRich(_ parsed: ParsedBlock) {
            sortKey = .between(sortKey, nil)
            let block = Block(pageId: pageId, kind: parsed.kind, text: parsed.text, indent: parsed.indent,
                              isChecked: parsed.kind == .checkbox && parsed.isChecked, sortKey: sortKey!,
                              color: parsed.color, props: parsed.props)
            result.append(block)
            func appendContained(_ children: [ParsedBlock], in containerId: UUID) {
                var key: FractionalSortKey?
                for child in children {
                    key = .between(key, nil)
                    let inner = Block(pageId: pageId, kind: child.kind, text: child.text, indent: child.indent,
                                      isChecked: child.kind == .checkbox && child.isChecked, sortKey: key!, containerId: containerId,
                                      color: child.color, props: child.props)
                    result.append(inner)
                    appendContained(child.contained, in: inner.id)
                }
            }
            appendContained(parsed.contained, in: block.id)
        }
        for block in page.blocks {
            if let target = NotionExportReader.linkedPage(block, from: index, in: plan) {
                if page.children.contains(target) { linkedChildren.insert(target) }
                append(.pageLink, link: ids[target])
            } else if block.kind == .pageLink {
                append(.paragraph, block.text)
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
                let items = NotionSimplification.allCases.compactMap { kind -> String? in
                    guard let count = page.simplifications[kind], count > 0 else { return nil }
                    return kind.title(count: count)
                }
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
