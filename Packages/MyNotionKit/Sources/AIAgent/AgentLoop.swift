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

    public var message: String {
        switch self {
        case .tooManySteps: "Агент сделал слишком много шагов подряд и остановился. Напишите, продолжать ли."
        }
    }
}

/// Ход агента: модель → инструменты → модель, пока модель не ответит без вызовов.
/// Остановка — отменой задачи, читающей поток: недописанное сохраняет тот, кто показывает чат.
public struct AgentLoop: Sendable {
    private let model: any ChatModelClient
    private let toolbox: NoteToolbox
    private let maxSteps: Int

    public init(model: any ChatModelClient, toolbox: NoteToolbox, maxSteps: Int = 30) {
        self.model = model
        self.toolbox = toolbox
        self.maxSteps = maxSteps
    }

    public func run(entries: [ChatEntry], model chatModel: ChatModel, level: ReasoningLevel) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await loop(entries: entries, chatModel: chatModel, level: chatModel.resolvedLevel(level), continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func loop(entries: [ChatEntry], chatModel: ChatModel, level: ReasoningLevel,
                      continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation) async throws {
        var history = entries
        for _ in 0..<maxSteps {
            let id = UUID()
            var turn = ModelTurn()
            let request = ModelRequest(messages: AgentPrompt.messages(for: history), tools: NoteToolbox.tools, level: level)
            for try await event in model.stream(request, model: chatModel) {
                turn.apply(event)
                continuation.yield(.delta(id, event))
            }
            try Task.checkCancellation()
            let answer = ChatEntry.assistant(turn: turn, modelID: chatModel.id, id: id)
            history.append(answer)
            continuation.yield(.entry(answer))
            if turn.toolCalls.isEmpty { return }
            for call in turn.toolCalls {
                try Task.checkCancellation()
                let title = NoteToolbox.title(for: call)
                continuation.yield(.toolStarted(callID: call.id, title: title))
                let outcome = await toolbox.run(call)
                let result = ChatEntry.tool(callID: call.id, name: call.name, outcome: outcome, title: title)
                history.append(result)
                continuation.yield(.entry(result))
            }
        }
        throw AgentError.tooManySteps
    }
}
