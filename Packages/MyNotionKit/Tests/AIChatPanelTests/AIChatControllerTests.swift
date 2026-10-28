import AIAgent
import AIChatHistory
import AIModels
import ControlProtocol
import Foundation
import NotesCore
import Synchronization
import Testing
@testable import AIChatPanel

/// Подменная модель: на каждый запрос — следующий заготовленный ответ. `hang` — молчит, пока ответ не остановят.
final class ScriptedModel: ChatModelClient {
    enum Reply: Sendable {
        case events([ModelStreamEvent])
        case failure(any Error)
        case hang([ModelStreamEvent])
    }

    private let replies: Mutex<[Reply]>
    private let seen = Mutex<[ModelRequest]>([])
    private let terminations = Mutex(0)

    init(_ replies: [Reply]) { self.replies = Mutex(replies) }

    var requests: [ModelRequest] { seen.withLock { $0 } }
    /// Сколько ответов закрыто — дочитанных или остановленных.
    var closed: Int { terminations.withLock { $0 } }

    func stream(_ request: ModelRequest, model: ChatModel) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        seen.withLock { $0.append(request) }
        let reply = replies.withLock { $0.isEmpty ? .events([.text("…")]) : $0.removeFirst() }
        return AsyncThrowingStream { continuation in
            let task = Task {
                switch reply {
                case .events(let events):
                    for event in events { continuation.yield(event) }
                    continuation.finish()
                case .failure(let error):
                    continuation.finish(throwing: error)
                case .hang(let events):
                    for event in events { continuation.yield(event) }
                    try? await Task.sleep(for: .seconds(60))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                self.terminations.withLock { $0 += 1 }
            }
        }
    }
}

/// Задвижка: тот, кто ждёт, стоит, пока тест не откроет. Отмена ожидания не прерывает.
final class Gate: Sendable {
    private let state = Mutex<(isOpen: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))
    private let arrivals = Mutex(0)

    var waiting: Int { arrivals.withLock { $0 } }

    func wait() async {
        arrivals.withLock { $0 += 1 }
        await withCheckedContinuation { continuation in
            let resumeNow = state.withLock { state -> Bool in
                if state.isOpen { return true }
                state.waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func open() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.isOpen = true
            defer { state.waiters = [] }
            return state.waiters
        }
        waiters.forEach { $0.resume() }
    }
}

final class TemporaryFolder: Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("AIChatPanelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}

/// Открытая страница под управлением теста.
@MainActor
final class PageHolder {
    var page: AIChatController.OpenPage?

    init(_ page: AIChatController.OpenPage?) { self.page = page }
}

@MainActor
@Suite("Контроллер панели ИИ-агента")
struct AIChatControllerTests {
    let folder: TemporaryFolder
    let chats: AIChatStore
    let defaults: UserDefaults
    let page = PageHolder(.init(pageID: "p1", title: "План", path: "Проекты/План", markdown: "# План\nКупить хлеб"))

    init() throws {
        folder = try TemporaryFolder()
        let notes = NotesStore(database: try AppDatabase.open(at: folder.url.appendingPathComponent("MyNotion.sqlite")),
                               clock: HybridLogicalClock(deviceId: UUID()))
        chats = AIChatStore(store: notes)
        defaults = UserDefaults(suiteName: "AIChatPanelTests-\(UUID().uuidString)")!
    }

    private func controller(_ model: ScriptedModel, commands: @escaping NoteToolbox.Runner = { .success($0.id, ["ok": true]) }) -> AIChatController {
        let holder = page
        return AIChatController(chats: chats, model: model, runner: commands, openPage: { holder.page }, defaults: defaults)
    }

    private func wait(until condition: () throws -> Bool) async throws {
        for _ in 0..<300 {
            if try condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func finish(_ controller: AIChatController) async throws {
        for _ in 0..<200 where controller.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!controller.isRunning)
    }

    @Test("Сообщение: новый чат с названием из сообщения, ответ в ленте и в базе, страница приложена")
    func send() async throws {
        let model = ScriptedModel([.events([.reasoning("думаю"), .text("Готово"), .finished("stop")])])
        let controller = controller(model)
        controller.draft = "Перескажи страницу кратко"
        controller.send()
        #expect(controller.draft.isEmpty)
        try await finish(controller)

        #expect(controller.entries.map(\.kind) == [.user, .assistant])
        #expect(controller.entries[1].text == "Готово")
        #expect(controller.entries[1].reasoning == "думаю")
        #expect(controller.entries[0].page?.path == "Проекты/План")
        #expect(controller.entries[0].page?.markdown == "# План\nКупить хлеб")
        let chat = try #require(controller.chatList.first)
        #expect(chat.id == controller.chatID)
        #expect(chat.title == "Перескажи страницу кратко")
        #expect(try chats.messages(in: chat.id).count == 2)
        #expect(controller.reply == nil)
    }

    @Test("Та же страница без правок — текст не повторяется; правка или другая страница — повторяется")
    func unchangedPage() async throws {
        let controller = controller(ScriptedModel([]))
        for text in ["раз", "два"] {
            controller.draft = text
            controller.send()
            try await finish(controller)
        }
        page.page?.markdown = "# План\nКупить молоко"
        controller.draft = "три"
        controller.send()
        try await finish(controller)
        let pages = controller.entries.filter { $0.kind == .user }.compactMap(\.page)
        #expect(pages.map(\.unchanged) == [false, true, false])
        #expect(pages[1].markdown.isEmpty)
        #expect(pages[2].markdown == "# План\nКупить молоко")
    }

    @Test("Длинная страница обрезается с пометкой")
    func longPage() async throws {
        page.page?.markdown = String(repeating: "а", count: AIChatController.pageTextLimit + 500)
        let controller = controller(ScriptedModel([]))
        controller.draft = "что тут?"
        controller.send()
        try await finish(controller)
        let context = try #require(controller.entries.first?.page)
        #expect(context.truncated)
        #expect(context.markdown.count == AIChatController.pageTextLimit)
    }

    @Test("Вызов инструмента: строка в ленте, команда выполнена от имени агента, затем ответ")
    func toolCall() async throws {
        let model = ScriptedModel([
            .events([.toolCall(ToolCallDelta(index: 0, id: "c1", name: "page_read", arguments: #"{"page":"current"}"#)), .finished("tool_calls")]),
            .events([.text("Прочитал"), .finished("stop")]),
        ])
        let seen = Mutex<[String]>([])
        let controller = controller(model) { request in
            seen.withLock { $0.append(request.command) }
            return .success(request.id, ["markdown": "# План"])
        }
        controller.draft = "Прочитай"
        controller.send()
        try await finish(controller)
        #expect(seen.withLock { $0 } == ["page.read"])
        #expect(controller.entries.map(\.kind) == [.user, .assistant, .tool, .assistant])
        #expect(controller.entries[2].title == "Читает открытую страницу")
        #expect(controller.entries[2].ok == true)
    }

    @Test("Ошибка модели — запись с понятной фразой, чат можно продолжить")
    func failure() async throws {
        let controller = controller(ScriptedModel([.failure(ModelError.missingKey(.openRouter)), .events([.text("Ок")])]))
        controller.draft = "Привет"
        controller.send()
        try await finish(controller)
        let failed = try #require(controller.entries.last)
        #expect(failed.kind == .assistant)
        #expect(failed.error == ModelError.missingKey(.openRouter).message)

        controller.draft = "Ещё раз"
        controller.send()
        try await finish(controller)
        #expect(controller.entries.last?.text == "Ок")
    }

    @Test("Непонятная ошибка — общая фраза без технических подробностей")
    func unknownFailure() async throws {
        struct Strange: Error {}
        let controller = controller(ScriptedModel([.failure(Strange())]))
        controller.draft = "Привет"
        controller.send()
        try await finish(controller)
        #expect(controller.entries.last?.error == AIChatController.genericErrorMessage)
    }

    @Test("«Стоп»: ответ прерван, пришедшее сохранено с пометкой «остановлено»")
    func stop() async throws {
        let controller = controller(ScriptedModel([.hang([.text("Начинаю")])]))
        controller.draft = "Напиши длинно"
        controller.send()
        for _ in 0..<200 where controller.reply?.text != "Начинаю" { try await Task.sleep(for: .milliseconds(10)) }
        #expect(controller.reply?.text == "Начинаю")
        controller.stop()
        try await finish(controller)
        let stopped = try #require(controller.entries.last)
        #expect(stopped.stopped == true)
        #expect(stopped.text == "Начинаю")
        #expect(stopped.error == nil)
        #expect(try chats.messages(in: #require(controller.chatID)).count == 2)
    }

    @Test("«Стоп» посреди инструмента: начатое действие доводится, его итог в чате и в базе — модель не повторит его вслепую")
    func stopDuringTool() async throws {
        let model = ScriptedModel([
            .events([.toolCall(ToolCallDelta(index: 0, id: "c1", name: "page_append", arguments: #"{"page":"current","markdown":"- пункт"}"#)),
                     .finished("tool_calls")]),
            .events([.text("лишнее")]),
        ])
        let gate = Gate()
        let controller = controller(model) { request in
            await gate.wait()
            return .success(request.id, ["ok": true])
        }
        controller.draft = "Допиши пункт"
        controller.send()
        try await wait { gate.waiting > 0 && controller.reply?.runningTool != nil }
        #expect(controller.reply?.runningTool != nil)
        controller.stop()
        try await Task.sleep(for: .milliseconds(50))
        gate.open()
        try await finish(controller)

        try #require(controller.entries.map(\.kind) == [.user, .assistant, .tool, .assistant])
        #expect(controller.entries[2].ok == true)
        #expect(controller.entries[3].stopped == true)
        #expect(model.requests.count == 1, "После «Стоп» модель больше не спрашивают")
        #expect(try chats.messages(in: #require(controller.chatID)).count == 4)
    }

    @Test("Панель закрыли вместе с окном — ответ модели останавливается, а не идёт дальше без хозяина")
    func droppedControllerStops() async throws {
        let model = ScriptedModel([.hang([.text("Начинаю")])])
        var panel: AIChatController? = controller(model)
        panel?.draft = "Наведи порядок"
        panel?.send()
        for _ in 0..<200 where panel?.reply?.text != "Начинаю" { try await Task.sleep(for: .milliseconds(10)) }
        #expect(panel?.reply?.text == "Начинаю")
        let chatID = try #require(panel?.chatID)
        panel = nil
        for _ in 0..<200 where model.closed == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.closed == 1)
        try await wait { try chats.messages(in: chatID).count >= 2 }
        let last = try #require(try chats.messages(in: chatID).last)
        #expect(try ChatEntryCoding.decode(last.body).stopped == true, "Пришедшее сохранено с пометкой «остановлено»")
    }

    @Test("Чат сменили, пока ход только начинался — сообщение остаётся в своём чате, в другой не попадает")
    func switchWhileStarting() async throws {
        let first = try chats.createChat(title: "Первый")
        let second = try chats.createChat(title: "Второй")
        let gate = Gate()
        let holder = page
        let model = ScriptedModel([])
        let controller = AIChatController(chats: chats, model: model, runner: { .success($0.id, [:]) },
                                          openPage: { await gate.wait(); return holder.page }, defaults: defaults)
        controller.openChat(first.id)
        controller.draft = "В первый"
        controller.send()
        for _ in 0..<200 where gate.waiting == 0 { try await Task.sleep(for: .milliseconds(10)) }
        controller.openChat(second.id)
        gate.open()
        try await wait { try chats.messages(in: first.id).count >= 2 }

        #expect(try chats.messages(in: second.id).isEmpty)
        let saved = try chats.messages(in: first.id).map { try ChatEntryCoding.decode($0.body) }
        #expect(saved.map(\.kind) == [.user, .assistant])
        #expect(saved.first?.text == "В первый")
        #expect(saved.last?.stopped == true)
        #expect(model.requests.isEmpty)
        #expect(controller.chatID == second.id)
        #expect(controller.entries.isEmpty)
    }

    @Test("Новый чат во время ответа: живой ответ не переезжает, новое сообщение уходит сразу")
    func newChatDuringReply() async throws {
        let model = ScriptedModel([.hang([.text("Старый ответ")]), .events([.text("Новый ответ")])])
        let controller = controller(model)
        controller.draft = "первый"
        controller.send()
        for _ in 0..<200 where controller.reply?.text != "Старый ответ" { try await Task.sleep(for: .milliseconds(10)) }
        let first = try #require(controller.chatID)
        controller.newChat()
        #expect(controller.reply == nil)
        #expect(!controller.isRunning)
        controller.draft = "второй"
        controller.send()
        #expect(controller.draft.isEmpty)
        try await finish(controller)
        #expect(controller.entries.map(\.text) == ["второй", "Новый ответ"])
        try await wait { try chats.messages(in: first).count >= 2 }
        #expect(try chats.messages(in: first).count == 2, "Старый ход дописал в свой чат пометку «остановлено»")
    }

    @Test("Пока идёт ответ, второе сообщение не уходит; пустое — тоже")
    func guards() async throws {
        let controller = controller(ScriptedModel([.hang([])]))
        controller.draft = "   "
        controller.send()
        #expect(!controller.isRunning)
        controller.draft = "раз"
        controller.send()
        controller.draft = "два"
        controller.send()
        #expect(controller.draft == "два")
        controller.stop()
        try await finish(controller)
    }

    @Test("Новый чат — пустая лента; прошлый открывается со своими записями")
    func pastChats() async throws {
        let controller = controller(ScriptedModel([]))
        controller.draft = "первый"
        controller.send()
        try await finish(controller)
        let first = try #require(controller.chatID)

        controller.newChat()
        #expect(controller.chatID == nil)
        #expect(controller.entries.isEmpty)
        #expect(controller.title == "Новый чат")
        controller.draft = "второй"
        controller.send()
        try await finish(controller)
        #expect(controller.chatList.map(\.title) == ["второй", "первый"])

        controller.openChat(first)
        #expect(controller.entries.first?.text == "первый")
        #expect(controller.title == "первый")
    }

    @Test("Действие пустого чата уходит сразу, без поля ввода")
    func pageAction() async throws {
        let model = ScriptedModel([])
        let controller = controller(model)
        let action = try #require(AIChatController.pageActions.first)
        controller.run(action)
        try await finish(controller)
        #expect(controller.entries.first?.text == action.prompt)
    }

    @Test("Модель и уровень запоминаются; уровень, которого у модели нет, заменяется её обычным")
    func modelChoice() throws {
        let first = controller(ScriptedModel([]))
        #expect(first.model == ModelCatalog.defaultModel)
        #expect(first.level == ModelCatalog.defaultModel.defaultLevel)
        first.select(ModelCatalog.glmFlash)
        #expect(first.level == ModelCatalog.glmFlash.defaultLevel)
        first.select(level: .high)
        first.select(ModelCatalog.qwenFlash)
        #expect(first.level == ModelCatalog.qwenFlash.defaultLevel)
        first.select(ModelCatalog.glmFlash)
        #expect(first.level == .high)

        let second = controller(ScriptedModel([]))
        #expect(second.model == ModelCatalog.glmFlash)
        #expect(second.level == .high)
    }

    @Test("Ход идёт выбранной моделью и уровнем")
    func requestUsesChoice() async throws {
        let model = ScriptedModel([])
        let controller = controller(model)
        controller.select(ModelCatalog.qwenFlash)
        controller.select(level: .high)
        controller.draft = "Привет"
        controller.send()
        try await finish(controller)
        #expect(model.requests.first?.level == .high)
        #expect(controller.entries.last?.modelID == ModelCatalog.qwenFlash.id)
    }

    @Test("Чат с другого устройства появляется в списке")
    func remoteChat() async throws {
        let controller = controller(ScriptedModel([]))
        try chats.createChat(title: "С iPhone")
        for _ in 0..<100 where controller.chatList.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(controller.chatList.map(\.title) == ["С iPhone"])
    }

    @Test("Название чата — первая строка сообщения, длинная обрезается")
    func titles() {
        #expect(AIChatController.chatTitle(from: "  Привет\nещё") == "Привет")
        let long = AIChatController.chatTitle(from: String(repeating: "б", count: 200))
        #expect(long.count == AIChatController.titleLimit + 1)
        #expect(long.hasSuffix("…"))
    }
}

@Suite("Прошлые чаты по срокам")
struct PastChatGroupsTests {
    @Test("Сегодня, вчера, неделя, месяц, раньше; поиск по названию без регистра")
    func groups() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 15)))
        func chat(_ title: String, daysAgo: Int) -> PastChatGroups.Item {
            PastChatGroups.Item(id: UUID(), title: title, updatedAt: calendar.date(byAdding: .day, value: -daysAgo, to: now)!)
        }
        let items = [chat("План", daysAgo: 0), chat("Отпуск", daysAgo: 1), chat("Задачи", daysAgo: 5), chat("Книги", daysAgo: 20),
                     chat("Старое", daysAgo: 90)]
        let groups = PastChatGroups.make(items, query: "", now: now, calendar: calendar)
        #expect(groups.map(\.title) == ["Сегодня", "Вчера", "Последние 7 дней", "Последние 30 дней", "Раньше"])
        #expect(groups.map { $0.items.map(\.title) } == [["План"], ["Отпуск"], ["Задачи"], ["Книги"], ["Старое"]])
        #expect(PastChatGroups.make(items, query: "ОТП", now: now, calendar: calendar).flatMap(\.items).map(\.title) == ["Отпуск"])
    }
}
