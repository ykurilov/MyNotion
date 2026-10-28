import AIAgent
import AIChatHistory
import AIModels
import Foundation
import Observation

/// Панель ИИ-агента одного окна: список прошлых чатов, открытый чат, ответ, который идёт сейчас, выбор модели и уровня.
/// Записи чата хранятся в базе заметок (`AIChatStore`) и уходят на другие устройства; ответ модели — потоком.
@MainActor
@Observable
public final class AIChatController {
    /// Открытая у человека страница в момент сообщения.
    public struct OpenPage: Sendable, Hashable {
        public var pageID: String
        public var title: String
        public var path: String
        public var markdown: String

        public init(pageID: String, title: String, path: String, markdown: String) {
            self.pageID = pageID
            self.title = title
            self.path = path
            self.markdown = markdown
        }
    }

    /// Ответ, который приходит сейчас.
    public struct LiveReply: Sendable, Hashable {
        public var reasoning = ""
        public var text = ""
        /// Подпись инструмента, который выполняется.
        public var runningTool: String?
    }

    /// Готовая просьба пустого чата про открытую страницу.
    public struct PageAction: Sendable, Hashable, Identifiable {
        public let id: String
        public let title: String
        public let symbol: String
        public let prompt: String
    }

    /// Окно поверх панели: прошлые чаты под заголовком или список над полем ввода.
    public enum Popup: Sendable, Hashable { case pastChats, models, levels }

    public static let newChatTitle = "Новый чат"
    public static let genericErrorMessage = "Не получилось получить ответ. Попробуйте ещё раз."
    public static let saveErrorMessage = "Не получилось сохранить сообщение. Текст вернулся в поле ввода."
    /// Сколько текста открытой страницы прикладывать к сообщению: дальше агент читает сам (`page_read`).
    public static let pageTextLimit = 20_000
    static let titleLimit = 60
    /// Как часто живой ответ перерисовывается: каждый кусочек потока — слишком часто для длинного ответа.
    static let replyInterval = Duration.milliseconds(50)

    public static let pageActions = [
        PageAction(id: "summary", title: "Пересказать страницу", symbol: "text.alignleft", prompt: "Кратко перескажи эту страницу."),
        PageAction(id: "translate", title: "Перевести страницу", symbol: "character.bubble", prompt: "Переведи эту страницу на английский."),
        PageAction(id: "insights", title: "Найти главное", symbol: "lightbulb", prompt: "Найди на этой странице главные мысли и выводы."),
        PageAction(id: "tasks", title: "Составить список задач", symbol: "checklist", prompt: "Составь по этой странице список задач."),
    ]

    public var isOpen = false
    public var draft = ""
    public var popup: Popup? {
        didSet { if popup != .pastChats { chatMenu = nil } }
    }
    /// Строка прошлого чата, у которой открыто меню.
    public var chatMenu: UUID?
    public private(set) var chatList: [AIChat] = []
    public private(set) var chatID: UUID?
    public private(set) var entries: [ChatEntry] = []
    public private(set) var reply: LiveReply?
    public private(set) var model: ChatModel
    public private(set) var level: ReasoningLevel

    @ObservationIgnored private let chats: AIChatStore
    @ObservationIgnored private let loop: AgentLoop
    @ObservationIgnored private let openPage: @MainActor () async -> OpenPage?
    @ObservationIgnored private let defaults: UserDefaults
    /// Ход, который показывает панель. Смена чата отцепляет его: ход дописывает свой чат в базе, а ленту не трогает.
    private var run: Run?
    /// Ход агента для остановки при закрытии окна — из `deinit`, где состояние панели уже недоступно.
    @ObservationIgnored private nonisolated(unsafe) var liveAgent: AgentRun?
    @ObservationIgnored private var pendingReply: LiveReply?
    @ObservationIgnored private var replyFlush: Task<Void, Never>?
    @ObservationIgnored private nonisolated(unsafe) var observer: NSObjectProtocol?

    @MainActor
    private final class Run {
        var isStopped = false
        var agent: AgentRun?

        func stop() {
            isStopped = true
            agent?.stop()
        }
    }

    public init(chats: AIChatStore, model client: any ChatModelClient, runner: @escaping NoteToolbox.Runner,
                openPage: @escaping @MainActor () async -> OpenPage?, defaults: UserDefaults = .standard) {
        self.chats = chats
        loop = AgentLoop(model: client, toolbox: NoteToolbox(runner: runner))
        self.openPage = openPage
        self.defaults = defaults
        let model = defaults.string(forKey: Keys.model).flatMap(ModelCatalog.model(id:)) ?? ModelCatalog.defaultModel
        self.model = model
        level = Self.savedLevel(for: model, in: defaults)
        observer = NotificationCenter.default.addObserver(forName: AIChatStore.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
    }

    /// Окно закрыли — ответ останавливается: досмотреть и остановить его больше негде.
    deinit {
        liveAgent?.stop()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    public var isRunning: Bool { run != nil }

    public var title: String {
        chatID.flatMap { id in chatList.first { $0.id == id }?.title } ?? Self.newChatTitle
    }

    // MARK: Действия

    public func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning else { return }
        draft = ""
        start(text)
    }

    public func run(_ action: PageAction) {
        guard !isRunning else { return }
        start(action.prompt)
    }

    /// Ответ прерывается; пришедшее сохраняется с пометкой «остановлено». Начатый инструмент доводится до конца.
    public func stop() {
        run?.stop()
    }

    public func newChat() {
        popup = nil
        closeChat()
    }

    public func openChat(_ id: UUID) {
        detachRun()
        popup = nil
        chatID = id
        entries = loadEntries(id)
    }

    /// Меню строки прошлого чата: открывается у одной строки, повторное нажатие закрывает.
    public func toggleChatMenu(_ id: UUID) { chatMenu = chatMenu == id ? nil : id }

    /// Чат удаляется на всех устройствах. Открытый — панель переходит в пустой новый чат, список прошлых остаётся открытым.
    public func deleteChat(_ id: UUID) {
        chatMenu = nil
        if chatID == id { closeChat() }
        try? chats.delete(id)
    }

    public func select(_ model: ChatModel) {
        popup = nil
        self.model = model
        level = Self.savedLevel(for: model, in: defaults)
        defaults.set(model.id, forKey: Keys.model)
    }

    public func select(level: ReasoningLevel) {
        popup = nil
        guard model.supports(level) else { return }
        self.level = level
        defaults.set(level.rawValue, forKey: Keys.level(model))
    }

    public func toggle(_ popup: Popup) {
        self.popup = self.popup == popup ? nil : popup
    }

    // MARK: Ход

    /// Ход не держит панель: закрыли окно — панель уходит, а ход останавливается (`deinit`) и дописывает свой чат в базе.
    private func start(_ text: String) {
        let model = model
        let level = level
        let origin = chatID
        let run = Run()
        self.run = run
        clearReply()
        reply = LiveReply()
        Task { [weak self, chats, loop, openPage] in
            let page = await openPage()
            // Сообщение — в чат, где его отправили, даже если чат успели сменить.
            guard let saved = self?.saveUser(text, page: page, origin: origin, run: run) else {
                self?.finish(run)
                return
            }
            let (chatID, history) = saved
            let record = { [weak self] (entry: ChatEntry) in
                if let self { self.save(entry, in: chatID) } else { Self.store(entry, in: chatID, chats: chats) }
            }
            if run.isStopped {
                record(.failedAssistant(error: nil, stopped: true, modelID: model.id))
                self?.finish(run)
                return
            }
            let agent = loop.start(entries: history, model: model, level: level)
            run.agent = agent
            self?.attach(agent, of: run)
            var turn = ModelTurn()
            do {
                for try await event in agent.events {
                    switch event {
                    case .delta(_, let delta):
                        turn.apply(delta)
                        let (reasoning, text) = (turn.reasoning, turn.text)
                        self?.updateReply(of: run) { $0.reasoning = reasoning; $0.text = text }
                    case .toolStarted(_, let title):
                        self?.updateReply(of: run, immediately: true) { $0.runningTool = title }
                    case .entry(let entry):
                        record(entry)
                        turn = ModelTurn()
                        self?.updateReply(of: run, immediately: true) { $0 = LiveReply() }
                    }
                }
            } catch {
                let stopped = run.isStopped || error is CancellationError
                record(.failedAssistant(turn: turn, error: stopped ? nil : Self.message(for: error), stopped: stopped, modelID: model.id))
            }
            self?.finish(run)
        }
    }

    /// Живой ответ меняет только ход, который панель показывает. Кусочки копятся и выходят на экран не чаще
    /// `replyInterval`: длинный ответ иначе перерисовывается и разбирается заново на каждый кусочек.
    private func updateReply(of run: Run, immediately: Bool = false, _ change: (inout LiveReply) -> Void) {
        guard self.run === run, var next = pendingReply ?? reply else { return }
        change(&next)
        pendingReply = next
        if immediately { return flushReply() }
        guard replyFlush == nil else { return }
        replyFlush = Task { [weak self] in
            try? await Task.sleep(for: Self.replyInterval)
            self?.flushReply()
        }
    }

    private func flushReply() {
        replyFlush?.cancel()
        replyFlush = nil
        if let pendingReply, run != nil { reply = pendingReply }
        pendingReply = nil
    }

    private func clearReply() {
        replyFlush?.cancel()
        replyFlush = nil
        pendingReply = nil
        reply = nil
    }

    private func attach(_ agent: AgentRun, of run: Run) {
        if self.run === run { liveAgent = agent }
    }

    private func closeChat() {
        detachRun()
        chatID = nil
        entries = []
    }

    /// Ход отцепляется от панели и останавливается; панель свободна для нового сообщения сразу.
    private func detachRun() {
        run?.stop()
        run = nil
        clearReply()
        liveAgent = nil
    }

    private func finish(_ run: Run) {
        guard self.run === run else { return }
        self.run = nil
        clearReply()
        liveAgent = nil
    }

    /// Сообщение человека в базу; первое сообщение начинает чат с названием из него. Возвращает чат и записи для модели.
    /// Не записалось — текст возвращается в поле ввода, а в ленте фраза об ошибке.
    private func saveUser(_ text: String, page: OpenPage?, origin: UUID?, run: Run) -> (UUID, [ChatEntry])? {
        let isShown = self.run === run
        let history = isShown ? entries : origin.map(loadEntries) ?? []
        let entry = ChatEntry.user(text, page: page.map { pageContext($0, history: history) })
        let chatID: UUID
        do {
            if let origin {
                chatID = origin
            } else {
                chatID = try chats.createChat(title: Self.chatTitle(from: text)).id
                if isShown { self.chatID = chatID }
            }
            try chats.append(try ChatEntryCoding.encode(entry), id: entry.id, to: chatID, at: entry.createdAt)
        } catch {
            if isShown {
                if draft.isEmpty { draft = text }
                entries.append(.failedAssistant(error: Self.saveErrorMessage, modelID: model.id))
            }
            return nil
        }
        if self.chatID == chatID { entries.append(entry) }
        return (chatID, history + [entry])
    }

    private func save(_ entry: ChatEntry, in chatID: UUID) {
        // Чат сменили, пока шёл ответ: дописывается в свой чат, а лента показывает открытый.
        if self.chatID == chatID { entries.append(entry) }
        Self.store(entry, in: chatID, chats: chats)
    }

    private static func store(_ entry: ChatEntry, in chatID: UUID, chats: AIChatStore) {
        guard let body = try? ChatEntryCoding.encode(entry) else { return }
        try? chats.append(body, id: entry.id, to: chatID, at: entry.createdAt)
    }

    /// Страница к сообщению. Та же страница с тем же текстом, что у прошлого сообщения, — без текста: так запрос
    /// короче, а его начало остаётся в кэше поставщика.
    private func pageContext(_ page: OpenPage, history: [ChatEntry]) -> PageContext {
        let truncated = page.markdown.count > Self.pageTextLimit
        let markdown = truncated ? String(page.markdown.prefix(Self.pageTextLimit)) : page.markdown
        if let previous = Self.lastPageText(in: history), previous.pageID == page.pageID, previous.markdown == markdown {
            return PageContext(pageID: page.pageID, title: page.title, path: page.path, markdown: "", truncated: truncated, unchanged: true)
        }
        return PageContext(pageID: page.pageID, title: page.title, path: page.path, markdown: markdown, truncated: truncated)
    }

    /// Страница прошлого сообщения и её текст — из последней записи, где он был целиком.
    private static func lastPageText(in entries: [ChatEntry]) -> (pageID: String, markdown: String)? {
        let users = entries.filter { $0.kind == .user }
        guard let last = users.last?.page else { return nil }
        let full = users.reversed().compactMap(\.page).prefix { $0.pageID == last.pageID }.first { !$0.unchanged }
        return full.map { (last.pageID, $0.markdown) }
    }

    // MARK: Список и записи

    private func reload() {
        chatList = (try? chats.chats()) ?? []
        // Открытый чат удалили на другом устройстве.
        if let chatID, let exists = try? chats.chat(chatID) != nil, !exists { return closeChat() }
        // Запись с другого устройства — в ленту, если сейчас не идёт свой ответ.
        if let chatID, !isRunning {
            let stored = loadEntries(chatID)
            if stored.count != entries.count { entries = stored }
        }
    }

    private func loadEntries(_ chatID: UUID) -> [ChatEntry] {
        ((try? chats.messages(in: chatID)) ?? []).compactMap { try? ChatEntryCoding.decode($0.body) }
    }

    // MARK: Правила

    static func chatTitle(from text: String) -> String {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count > titleLimit ? String(trimmed.prefix(titleLimit)) + "…" : trimmed
    }

    static func message(for error: any Error) -> String {
        switch error {
        case let error as ModelError: error.message
        case let error as AgentError: error.message
        case let error as URLError: error.code == .timedOut ? ModelError.timeout.message : ModelError.network.message
        default: genericErrorMessage
        }
    }

    private static func savedLevel(for model: ChatModel, in defaults: UserDefaults) -> ReasoningLevel {
        model.resolvedLevel(defaults.string(forKey: Keys.level(model)).flatMap(ReasoningLevel.init(rawValue:)) ?? model.defaultLevel)
    }

    private enum Keys {
        static let model = "AIChat.model"
        static func level(_ model: ChatModel) -> String { "AIChat.level.\(model.id)" }
    }
}

/// Запись чата в базе — JSON. Незнакомую запись (от новой версии) лента пропускает.
public enum ChatEntryCoding {
    public static func encode(_ entry: ChatEntry) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(entry), as: UTF8.self)
    }

    public static func decode(_ body: String) throws -> ChatEntry {
        try JSONDecoder().decode(ChatEntry.self, from: Data(body.utf8))
    }
}
