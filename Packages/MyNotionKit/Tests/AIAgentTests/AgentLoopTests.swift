import AIModels
import ControlProtocol
import Foundation
import Synchronization
import Testing
@testable import AIAgent

/// Подменная модель: ответы по очереди, запросы запоминаются.
final class ScriptedModel: ChatModelClient {
    private let turns: Mutex<[[ModelStreamEvent]]>
    private let requests = Mutex<[ModelRequest]>([])
    private let repeatLast: Bool

    init(_ turns: [[ModelStreamEvent]], repeatLast: Bool = false) {
        self.turns = Mutex(turns)
        self.repeatLast = repeatLast
    }

    var seen: [ModelRequest] { requests.withLock { $0 } }

    func stream(_ request: ModelRequest, model: ChatModel) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        requests.withLock { $0.append(request) }
        let events = turns.withLock { queue -> [ModelStreamEvent] in
            guard !queue.isEmpty else { return [] }
            return repeatLast && queue.count == 1 ? queue[0] : queue.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

private func toolCall(_ id: String, _ name: String, _ arguments: String) -> ModelStreamEvent {
    .toolCall(ToolCallDelta(index: 0, id: id, name: name, arguments: arguments))
}

private let page = PageContext(pageID: "p1", title: "План", path: "Проекты/План", markdown: "# План\n- пункт", truncated: false)

@Suite("Запрос к модели из чата")
struct AgentPromptTests {
    @Test("Системная инструкция первой; страница — внутри сообщения, к которому её приложили")
    func layout() throws {
        let messages = AgentPrompt.messages(for: [.user("Перескажи", page: page)])
        #expect(messages.count == 2)
        #expect(messages[0] == .system(AgentPrompt.systemInstruction))
        #expect(messages[1].role == .user)
        let text = messages[1].content
        #expect(text.contains("Проекты/План"))
        #expect(text.contains("# План\n- пункт"))
        let request = try #require(text.range(of: "Перескажи"))
        let pageText = try #require(text.range(of: "# План"))
        #expect(pageText.lowerBound < request.lowerBound)
    }

    @Test("У открытой страницы — id родителя: «рядом» создаётся без поиска по названиям")
    func parentOfPage() {
        var child = page
        child.parentID = "parent-1"
        #expect(AgentPrompt.messages(for: [.user("Создай рядом", page: child)])[1].content.contains(#"родитель_id="parent-1""#))
        #expect(!AgentPrompt.messages(for: [.user("Создай рядом", page: page)])[1].content.contains("родитель_id"))
    }

    @Test("Та же страница без изменений не повторяется целиком")
    func unchangedPage() {
        var same = page
        same.unchanged = true
        let text = AgentPrompt.messages(for: [.user("Ещё", page: same)])[1].content
        #expect(!text.contains("# План\n- пункт"))
        #expect(text.contains("Проекты/План"))
    }

    @Test("Рассуждения возвращаются только в ходе с инструментами; ответ с одной ошибкой не уходит")
    func reasoning() {
        var withTools = ModelTurn()
        withTools.apply(.reasoning("надо прочитать"))
        withTools.apply(toolCall("c1", "page_read", #"{"page":"current"}"#))
        var answer = ModelTurn()
        answer.apply(.reasoning("готово"))
        answer.apply(.text("Вот пересказ"))
        let entries: [ChatEntry] = [
            .user("Перескажи", page: nil),
            .assistant(turn: withTools, modelID: "deepseek-flash"),
            .tool(callID: "c1", name: "page_read", outcome: ToolOutcome(ok: true, output: "текст"), title: "Читает"),
            .assistant(turn: answer, modelID: "deepseek-flash"),
            .failedAssistant(error: "Нет связи с интернетом.", modelID: "deepseek-flash"),
        ]
        let messages = AgentPrompt.messages(for: entries)
        #expect(messages.map(\.role) == [.system, .user, .assistant, .tool, .assistant])
        #expect(messages[2].reasoning == "надо прочитать")
        #expect(messages[2].toolCalls.map(\.id) == ["c1"])
        #expect(messages[3] == .tool(callID: "c1", content: "текст"))
        #expect(messages[4].reasoning == nil)
        #expect(messages[4].content == "Вот пересказ")
    }

    @Test("Вызов без результата (остановили) получает ответ «не выполнено» — иначе поставщик откажет")
    func orphanCall() {
        var turn = ModelTurn()
        turn.apply(toolCall("c9", "page_trash", #"{"page":"x"}"#))
        let messages = AgentPrompt.messages(for: [.user("Удали", page: nil), .assistant(turn: turn, modelID: "glm-flash"), .user("Стоп", page: nil)])
        #expect(messages.map(\.role) == [.system, .user, .assistant, .tool, .user])
        #expect(messages[3].toolCallID == "c9")
        #expect(!messages[3].content.isEmpty)
    }

    @Test("Новое сообщение не меняет начало запроса — кэш поставщика работает")
    func stablePrefix() {
        var turn = ModelTurn()
        turn.apply(.text("Ответ"))
        let before: [ChatEntry] = [.user("Один", page: page), .assistant(turn: turn, modelID: "glm-flash")]
        let after = before + [.user("Два", page: page)]
        let short = AgentPrompt.messages(for: before)
        let long = AgentPrompt.messages(for: after)
        #expect(Array(long.prefix(short.count)) == short)
    }

    @Test("Инструкция: открытая страница, действовать без вопросов, удаление только в корзину, по-русски")
    func instruction() {
        let text = AgentPrompt.systemInstruction
        for part in ["открыт", "корзин", "current", "по-русски"] { #expect(text.contains(part), "Нет «\(part)»") }
    }
}

@Suite("Цикл агента")
struct AgentLoopTests {
    private func run(_ loop: AgentLoop, _ entries: [ChatEntry]) async throws -> [ChatEntry] {
        var finished: [ChatEntry] = []
        for try await event in loop.run(entries: entries, model: ModelCatalog.glmFlash, level: .medium) {
            if case .entry(let entry) = event { finished.append(entry) }
        }
        return finished
    }

    @Test("Модель → инструмент → модель: результат уходит в следующий запрос, ответ — последним")
    func toolRoundTrip() async throws {
        let model = ScriptedModel([[toolCall("c1", "page_read", #"{"page":"current"}"#), .finished("tool_calls")],
                                   [.text("На странице план."), .finished("stop")]])
        let commands = FakeCommands { .success($0.id, ["markdown": "# План"]) }
        let loop = AgentLoop(model: model, toolbox: NoteToolbox(runner: commands.runner))
        let entries = try await run(loop, [.user("Что тут?", page: page)])
        #expect(entries.map(\.kind) == [.assistant, .tool, .assistant])
        #expect(entries[1].callID == "c1")
        #expect(entries[1].ok == true)
        #expect(entries[2].text == "На странице план.")
        #expect(model.seen.count == 2)
        #expect(model.seen[1].messages.last == .tool(callID: "c1", content: ##"{"markdown":"# План"}"##))
        #expect(model.seen.allSatisfy { $0.level == .medium && $0.tools == NoteToolbox.tools })
        #expect(commands.seen.map(\.command) == ["page.read"])
    }

    @Test("Живые события: части ответа помечены id будущей записи, вызов инструмента — подписью")
    func liveEvents() async throws {
        let model = ScriptedModel([[toolCall("c1", "search", #"{"query":"отпуск"}"#)], [.text("Нашёл")]])
        let loop = AgentLoop(model: model, toolbox: NoteToolbox(runner: FakeCommands().runner))
        var streamedIDs: Set<UUID> = []
        var toolTitles: [String] = []
        var finishedIDs: [UUID] = []
        for try await event in loop.run(entries: [.user("Найди", page: nil)], model: ModelCatalog.glmFlash, level: .low) {
            switch event {
            case .delta(let id, _): streamedIDs.insert(id)
            case .toolStarted(_, let title): toolTitles.append(title)
            case .entry(let entry): finishedIDs.append(entry.id)
            }
        }
        #expect(toolTitles == ["Ищет «отпуск»"])
        #expect(streamedIDs.isSubset(of: Set(finishedIDs)))
        #expect(streamedIDs.count == 2)
    }

    @Test("Слишком много шагов — понятная ошибка, а не вечный цикл")
    func stepLimit() async throws {
        let model = ScriptedModel([[toolCall("c", "page_tree", "{}")]], repeatLast: true)
        let loop = AgentLoop(model: model, toolbox: NoteToolbox(runner: FakeCommands().runner), maxSteps: 3)
        await #expect(throws: AgentError.tooManySteps) { _ = try await run(loop, [.user("Крутись", page: nil)]) }
        #expect(model.seen.count == 3)
        #expect(!AgentError.tooManySteps.message.isEmpty)
    }

    @Test("Ответ оборвался по длине посреди вызова — вызов не выполняется, понятная ошибка")
    func truncatedToolCall() async throws {
        let model = ScriptedModel([[toolCall("c1", "page_append", ##"{"page":"current","markdown":"# Нача"}"##), .finished("length")]])
        let commands = FakeCommands()
        let loop = AgentLoop(model: model, toolbox: NoteToolbox(runner: commands.runner))
        await #expect(throws: AgentError.truncatedToolCall) { _ = try await run(loop, [.user("Допиши", page: nil)]) }
        #expect(commands.seen.isEmpty)
        #expect(!AgentError.truncatedToolCall.message.isEmpty)
    }
}
