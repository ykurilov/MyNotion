import AIModels
import Foundation

public enum AgentEvent: Sendable {
    /// Кусочек ответа модели для записи `id`, которая придёт событием `.entry`.
    case delta(UUID, ModelStreamEvent)
    case toolStarted(callID: String, title: String)
    /// Готовая запись: её сохраняют и показывают.
    case entry(ChatEntry)
}

public enum AgentError: Error, Sendable, Hashable {
    case tooManySteps
    case truncatedToolCall

    public var message: String {
        switch self {
        case .tooManySteps: "Агент сделал слишком много шагов подряд и остановился. Напишите, продолжать ли."
        case .truncatedToolCall: "Ответ модели оборвался посреди действия, и оно не выполнено. Попробуйте ещё раз."
        }
    }
}

/// Идущий ход агента. `stop()` сразу прерывает ответ модели, а начатый инструмент доводит до конца и отдаёт его запись:
/// действие в заметках могло уже случиться, и в чате должен остаться его итог. Затем поток кончается `CancellationError`.
public final class AgentRun: Sendable {
    public let events: AsyncThrowingStream<AgentEvent, Error>
    private let task: Task<Void, Never>

    init(events: AsyncThrowingStream<AgentEvent, Error>, task: Task<Void, Never>) {
        self.events = events
        self.task = task
    }

    public func stop() { task.cancel() }
}

/// Ход агента: модель → инструменты → модель, пока модель не ответит без вызовов.
public struct AgentLoop: Sendable {
    private let model: any ChatModelClient
    private let toolbox: NoteToolbox
    private let maxSteps: Int

    public init(model: any ChatModelClient, toolbox: NoteToolbox, maxSteps: Int = 30) {
        self.model = model
        self.toolbox = toolbox
        self.maxSteps = maxSteps
    }

    public func start(entries: [ChatEntry], model chatModel: ChatModel, level: ReasoningLevel) -> AgentRun {
        let (events, continuation) = AsyncThrowingStream<AgentEvent, Error>.makeStream()
        let task = Task {
            do {
                try await loop(entries: entries, chatModel: chatModel, level: chatModel.resolvedLevel(level), continuation: continuation)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return AgentRun(events: events, task: task)
    }

    public func run(entries: [ChatEntry], model chatModel: ChatModel, level: ReasoningLevel) -> AsyncThrowingStream<AgentEvent, Error> {
        start(entries: entries, model: chatModel, level: level).events
    }

    private func loop(entries: [ChatEntry], chatModel: ChatModel, level: ReasoningLevel,
                      continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation) async throws {
        var history = entries
        for _ in 0..<maxSteps {
            try Task.checkCancellation()
            let id = UUID()
            var turn = ModelTurn()
            let request = ModelRequest(messages: AgentPrompt.messages(for: history), tools: NoteToolbox.tools, level: level)
            for try await event in model.stream(request, model: chatModel) {
                turn.apply(event)
                continuation.yield(.delta(id, event))
            }
            try Task.checkCancellation()
            // Ответ упёрся в предел длины: аргументы вызова могли оборваться и всё же разобраться — такое не выполнять.
            if turn.finishReason == "length", !turn.toolCalls.isEmpty { throw AgentError.truncatedToolCall }
            let answer = ChatEntry.assistant(turn: turn, modelID: chatModel.id, id: id)
            history.append(answer)
            continuation.yield(.entry(answer))
            if turn.toolCalls.isEmpty { return }
            for call in turn.toolCalls {
                try Task.checkCancellation()
                let title = NoteToolbox.title(for: call)
                continuation.yield(.toolStarted(callID: call.id, title: title))
                // Своей задачей: остановка хода не обрывает действие на середине, его итог доходит до чата.
                let toolbox = toolbox
                let outcome = await Task { await toolbox.run(call) }.value
                let result = ChatEntry.tool(callID: call.id, name: call.name, outcome: outcome, title: title)
                history.append(result)
                continuation.yield(.entry(result))
            }
        }
        throw AgentError.tooManySteps
    }
}
