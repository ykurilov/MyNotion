import Attachments
import ControlProtocol
import Databases
import Foundation
import NotesCore

/// Обработчик команды каталога. Изменяющий — только через операции сессии (`pageTree`, `databases`, документы): так
/// правку видят окна, поиск и синхронизация, и её можно откатить (research R3).
public typealias CommandHandler = @MainActor @Sendable (CommandSession) async throws -> CommandResult

/// Итог обработчика: `data` ответа и краткий текст для `--human`.
public struct CommandResult: Sendable, Hashable {
    public var data: ControlJSON
    public var text: String?

    public init(_ data: ControlJSON = [:], text: String? = nil) {
        self.data = data
        self.text = text
    }
}

/// Общее на одну команду или весь пакет: своя отмена (не окна), предупреждения, затронутые страницы, отметки
/// «до правки агента» (data-model.md, «CommandSession»).
@MainActor
final class SessionContext {
    let undoManager: UndoManager
    let pageTree: PageTreeOperations
    let databases: DatabaseOperations
    var warnings: [ControlWarning] = []
    var touchedPages: Set<UUID> = []
    /// Страницы, перед правкой которых версия «до правки агента» уже проверена.
    var checkpointedPages: Set<UUID> = []
    /// Снятые до правки виды страниц: версиями их записывает исполнитель после команды.
    var pendingCheckpoints: [AgentEditCheckpoint.Pending] = []
    /// Копии файлов, вложенные командой: откат стирает те, на которые после него никто не ссылается.
    var importedAttachments: [UUID] = []
    /// Последние правки агентов по страницам — общие для всех команд исполнителя.
    let agentWrites: AgentWriteTimes
    let progress: (ControlProgress) -> Void
    private let store: NotesStore
    private let attachments: AttachmentStore
    /// Начало команды: страницы, созданные позже, — её собственные.
    private let started = Date()

    init(host: any ControlHost, agentWrites: AgentWriteTimes, progress: @escaping (ControlProgress) -> Void) {
        store = host.store
        attachments = host.attachments
        self.agentWrites = agentWrites
        let undoManager = UndoManager()
        // Шаги отмены задаёт сама команда (`grouped`), а не цикл событий окна.
        undoManager.groupsByEvent = false
        self.undoManager = undoManager
        self.progress = progress
        pageTree = PageTreeOperations(store: host.store, undoManager: undoManager)
        databases = DatabaseOperations(store: host.store, undoManager: undoManager)
        pageTree.onChange = { [weak self, host] pageIds in
            self?.touchedPages.formUnion(pageIds)
            host.treeDidChange(pageIds)
        }
        pageTree.onIconChange = { [weak self, host] pageId, _ in
            self?.touchedPages.insert(pageId)
            host.iconDidChange(pageId)
        }
        pageTree.onAppearanceChange = { [weak self, host] pageId in
            self?.touchedPages.insert(pageId)
            host.appearanceDidChange(pageId)
        }
        databases.onChange = { [weak self, host] pageIds in
            self?.touchedPages.formUnion(pageIds)
            host.treeDidChange(pageIds)
        }
    }

    /// Один шаг отмены на всё, что сделает `body`.
    func grouped<T>(_ body: () async throws -> T) async rethrows -> T {
        undoManager.beginUndoGrouping()
        defer { undoManager.endUndoGrouping() }
        return try await body()
    }

    /// Откатить всё сделанное этой сессией: ошибка команды или шага пакета (research R6). Возвращается, когда всё
    /// уже вернулось: большая смена типа откатывается в фоне.
    func rollBack() async {
        while undoManager.canUndo {
            undoManager.undo()
        }
        if let rewrite = databases.pendingRewrite {
            do {
                try await rewrite.value
            } catch {
                warnings.append(ControlWarning(.partialRollback, "Свойство базы вернуть не удалось: \(error.localizedDescription)"))
            }
        }
        // Отмена создания кладёт страницу в корзину, как ⌘Z. Страницы самой команды стираются: неудачный пакет агента
        // не оставляет в корзине следов.
        let created = touchedPages.compactMap { try? store.page($0) }.filter { $0.trashedAt != nil && $0.createdAt >= started }
        for page in created {
            // Подстраница уже стёрта вместе с родителем — ошибка «нет страницы» не важна.
            try? pageTree.deleteForever(page.id)
        }
        // Файл, вложенный откаченной командой, — сирота: не ждать месяц, пока его уберёт чистка.
        for id in importedAttachments {
            try? attachments.discardIfUnreferenced(id)
        }
        importedAttachments = []
    }

    /// Откат не тронул блоки, которые после команды правили в окне или пришли с другого Mac.
    func keptOnRollback(_ count: Int, inPage pageId: UUID) {
        let title = (try? store.page(pageId))?.displayTitle ?? pageId.uuidString.lowercased()
        warnings.append(ControlWarning(.partialRollback, "«\(title)»: блоков, изменённых после команды, откат не тронул — \(count)"))
    }
}

/// Сессия команды: аргументы, указатели, вывод списков частями, ход, предупреждения и операции правки. Обработчики
/// этапов дописывают свои помощники расширениями `CommandSession` в своих файлах.
@MainActor
public final class CommandSession {
    public let host: any ControlHost
    public let request: ControlRequest
    public let spec: CommandSpec
    /// Проверенные по каталогу аргументы (значения по умолчанию уже подставлены).
    public let args: [String: ControlJSON]
    public let registry: HandlerRegistry
    let context: SessionContext

    init(host: any ControlHost, request: ControlRequest, spec: CommandSpec, args: [String: ControlJSON], registry: HandlerRegistry,
         context: SessionContext) {
        self.host = host
        self.request = request
        self.spec = spec
        self.args = args
        self.registry = registry
        self.context = context
    }

    /// Шаг пакета: те же отмена, предупреждения и отметки агента.
    func step(_ spec: CommandSpec, args: [String: ControlJSON]) -> CommandSession {
        var request = request
        request.command = spec.name
        request.args = args
        return CommandSession(host: host, request: request, spec: spec, args: args, registry: registry, context: context)
    }

    public var agent: String { request.agent }
    public var undoManager: UndoManager { context.undoManager }
    public var pageTree: PageTreeOperations { context.pageTree }
    public var databases: DatabaseOperations { context.databases }
    public var warnings: [ControlWarning] { context.warnings }
    public var touchedPages: Set<UUID> { context.touchedPages }
    public var includeTrashed: Bool { args["includeTrashed"]?.bool ?? false }

    // MARK: Аргументы

    public func string(_ key: String) -> String? { args[key]?.string }
    public func int(_ key: String) -> Int? { args[key]?.int }
    public func number(_ key: String) -> Double? { args[key]?.number }
    public func flag(_ key: String) -> Bool { args[key]?.bool ?? false }
    /// Список: повторённый аргумент или `a,b,c`.
    public func strings(_ key: String) -> [String] {
        if let items = args[key]?.array { return items.compactMap(\.string) }
        return args[key]?.string.map { [$0] } ?? []
    }

    // MARK: Указатели

    public var pageLocator: PageLocator {
        PageLocator(store: host.store, currentPageId: { [host] in host.windowControl.currentPageId })
    }

    public var blockLocator: BlockLocator { BlockLocator(store: host.store) }

    /// Страница по аргументу `key` (`page`, `parent`, `after`…): id, путь, `current`.
    public func page(_ key: String = "page") throws(ControlError) -> Page {
        guard let text = string(key) else {
            throw CommandCatalog.missing(named: key, in: spec)
        }
        return try pageLocator.resolve(text, includeTrashed: includeTrashed)
    }

    /// Необязательная страница: аргумента нет — `nil`.
    public func optionalPage(_ key: String) throws(ControlError) -> Page? {
        guard args[key] != nil else { return nil }
        return try page(key)
    }

    /// Блок по аргументу `key`; с `inPage` — блок обязан быть этой страницы (`wrong_page`).
    public func block(_ key: String = "block", inPage pageId: UUID? = nil) throws(ControlError) -> Block {
        guard let text = string(key) else {
            throw CommandCatalog.missing(named: key, in: spec)
        }
        return try blockLocator.resolve(text, inPage: pageId)
    }

    // MARK: Ответ

    /// Список частями (FR-409): `{"items":[…],"nextCursor":"<смещение>"|null}`. Курсор — смещение текстом, для агента
    /// непрозрачное.
    public func paged(_ items: [ControlJSON]) throws(ControlError) -> ControlJSON {
        let limit = int("limit") ?? CommandCatalog.defaultLimit
        var offset = 0
        if let cursor = args["cursor"] {
            guard let text = cursor.string, let value = Int(text), value >= 0 else {
                throw ControlError(.invalidValue, "--cursor — значение nextCursor из прошлого ответа", hint: "Начать сначала: без --cursor",
                                   details: ["argument": "cursor"])
            }
            // Курсор за концом списка — пустая часть; без сложения с огромным числом.
            offset = min(value, items.count)
        }
        let end = min(items.count, offset + limit)
        let page = offset < end ? Array(items[offset..<end]) : []
        return ["items": .array(page), "nextCursor": end < items.count ? .string(String(end)) : .null]
    }

    /// Строка хода долгой команды.
    public func report(_ progress: ControlProgress) {
        context.progress(progress)
    }

    public func warn(_ code: ControlWarningCode, _ message: String, line: Int? = nil) {
        context.warnings.append(ControlWarning(code, message, line: line))
    }

    // MARK: Правка

    /// Перед первой записью в страницу: версия «до правки агента» (раз на страницу за сессию, R7).
    public func willWrite(_ pageId: UUID) async throws {
        guard context.checkpointedPages.insert(pageId).inserted else { return }
        // Снимок — сейчас, без пауз до правки; версией он станет после команды (`CommandExecutor.write`).
        if let pending = try AgentEditCheckpoint(host: host).capture(pageId, agent: agent, lastAgentWrite: context.agentWrites[pageId]) {
            context.pendingCheckpoints.append(pending)
        }
    }

    /// Страницы, которые правка изменила мимо операций дерева (их окна перечитают).
    public func touch(_ pageIds: Set<UUID>) {
        context.touchedPages.formUnion(pageIds)
    }
}

extension CommandCatalog {
    static func missing(named name: String, in spec: CommandSpec) -> ControlError {
        let label = spec.argument(named: name).map { $0.flag.map { "--" + $0 } ?? "<\($0.name)>" } ?? name
        return ControlError(.missingArgument, "Не хватает аргумента \(label)", hint: "Пример: \(spec.example)",
                            details: ["argument": .string(name)])
    }
}
