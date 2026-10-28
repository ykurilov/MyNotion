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
    /// Сколько текста открытой страницы прикладывать к сообщению: дальше агент читает сам (`page_read`).
    public static let pageTextLimit = 20_000
    static let titleLimit = 60

    public static let pageActions = [
        PageAction(id: "summary", title: "Пересказать страницу", symbol: "text.alignleft", prompt: "Кратко перескажи эту страницу."),
        PageAction(id: "translate", title: "Перевести страницу", symbol: "character.bubble", prompt: "Переведи эту страницу на английский."),
        PageAction(id: "insights", title: "Найти главное", symbol: "lightbulb", prompt: "Найди на этой странице главные мысли и выводы."),
        PageAction(id: "tasks", title: "Составить список задач", symbol: "checklist", prompt: "Составь по этой странице список задач."),
    ]

    public var isOpen = false
    public var draft = ""
    public var popup: Popup?
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
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private nonisolated(unsafe) var observer: NSObjectProtocol?

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

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    public var isRunning: Bool { task != nil }

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

    /// Ответ прерывается; пришедшее сохраняется с пометкой «остановлено».
    public func stop() {
        task?.cancel()
    }

    public func newChat() {
        stop()
        popup = nil
        chatID = nil
        entries = []
    }

    public func openChat(_ id: UUID) {
        stop()
        popup = nil
        chatID = id
        entries = loadEntries(id)
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

    private func start(_ text: String) {
        let model = model
        let level = level
        reply = LiveReply()
        task = Task { [weak self] in
            guard let self else { return }
            let page = await openPage()
            guard let chatID = save(.user(text, page: page.map { pageContext($0) }), startingChat: text) else {
                finish()
                return
            }
            var turn = ModelTurn()
            do {
                for try await event in loop.run(entries: entries, model: model, level: level) {
                    switch event {
                    case .delta(_, let delta):
                        turn.apply(delta)
                        reply?.reasoning = turn.reasoning
                        reply?.text = turn.text
                    case .toolStarted(_, let title):
                        reply?.runningTool = title
                    case .entry(let entry):
                        save(entry, in: chatID)
                        turn = ModelTurn()
                        reply = LiveReply()
                    }
                }
                if Task.isCancelled { save(.failedAssistant(turn: turn, error: nil, stopped: true, modelID: model.id), in: chatID) }
            } catch {
                let stopped = Task.isCancelled || error is CancellationError
                save(.failedAssistant(turn: turn, error: stopped ? nil : Self.message(for: error), stopped: stopped, modelID: model.id),
                     in: chatID)
            }
            finish()
        }
    }

    private func finish() {
        task = nil
        reply = nil
    }

    /// Сообщение человека; первое сообщение начинает чат с названием из него.
    private func save(_ entry: ChatEntry, startingChat text: String) -> UUID? {
        if chatID == nil {
            guard let chat = try? chats.createChat(title: Self.chatTitle(from: text)) else { return nil }
            chatID = chat.id
        }
        guard let chatID else { return nil }
        save(entry, in: chatID)
        return chatID
    }

    private func save(_ entry: ChatEntry, in chatID: UUID) {
        // Чат сменили, пока шёл ответ: дописывается в свой чат, а лента показывает открытый.
        if self.chatID == chatID { entries.append(entry) }
        guard let body = try? ChatEntryCoding.encode(entry) else { return }
        try? chats.append(body, id: entry.id, to: chatID, at: entry.createdAt)
    }

    /// Страница к сообщению. Та же страница с тем же текстом, что у прошлого сообщения, — без текста: так запрос
    /// короче, а его начало остаётся в кэше поставщика.
    private func pageContext(_ page: OpenPage) -> PageContext {
        let truncated = page.markdown.count > Self.pageTextLimit
        let markdown = truncated ? String(page.markdown.prefix(Self.pageTextLimit)) : page.markdown
        if let previous = lastPageText(), previous.pageID == page.pageID, previous.markdown == markdown {
            return PageContext(pageID: page.pageID, title: page.title, path: page.path, markdown: "", truncated: truncated, unchanged: true)
        }
        return PageContext(pageID: page.pageID, title: page.title, path: page.path, markdown: markdown, truncated: truncated)
    }

    /// Страница прошлого сообщения и её текст — из последней записи, где он был целиком.
    private func lastPageText() -> (pageID: String, markdown: String)? {
        let users = entries.filter { $0.kind == .user }
        guard let last = users.last?.page else { return nil }
        let full = users.reversed().compactMap(\.page).prefix { $0.pageID == last.pageID }.first { !$0.unchanged }
        return full.map { (last.pageID, $0.markdown) }
    }

    // MARK: Список и записи

    private func reload() {
        chatList = (try? chats.chats()) ?? []
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
