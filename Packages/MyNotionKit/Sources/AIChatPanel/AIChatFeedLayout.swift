import AIAgent
import Foundation

/// Шаг агента между сообщениями: рассуждение или вызов инструмента.
struct AIChatStep: Hashable {
    enum Kind: Hashable { case reasoning, tool }
    enum State: Hashable { case running, done, failed }

    var kind: Kind
    var title: String
    /// Текст рассуждения — виден, когда шаг раскрыт.
    var detail: String?
    var state: State

    static let reasoningTitle = "Рассуждения"
    static let thinkingTitle = "Думает…"
}

/// Подряд идущие шаги агента — одной строкой-сводкой, как «Worked for 3s» в чате Notion AI.
struct AIChatStepGroup: Hashable {
    /// По записи перед шагами: не меняется, когда ход закончился, и раскрытая сводка остаётся раскрытой.
    var id: String
    var steps: [AIChatStep]
    var isRunning: Bool
    var summary: String

    /// Шаг, который идёт сейчас, — его видно вместо сводки, пока ход не закончился.
    var current: AIChatStep? { isRunning ? steps.last : nil }

    static func summary(seconds: Int) -> String {
        let seconds = max(seconds, 1)
        guard seconds >= 60 else { return "Работал \(seconds) с" }
        let rest = seconds % 60
        return rest == 0 ? "Работал \(seconds / 60) мин" : "Работал \(seconds / 60) мин \(rest) с"
    }
}

enum AIChatFeedItem: Hashable, Identifiable {
    case user(ChatEntry)
    case steps(AIChatStepGroup)
    /// Ответ модели: текст, ошибка или пометка «остановлено». Его рассуждения — в сводке шагов перед ним.
    case answer(ChatEntry)
    /// Текст ответа, который приходит сейчас.
    case liveText(String)

    var id: String {
        switch self {
        case .user(let entry), .answer(let entry): entry.id.uuidString
        case .steps(let group): group.id
        case .liveText: "live-text"
        }
    }
}

/// Раскладка ленты: записи чата и ответ, который идёт сейчас, — в сообщения, ответы и сводки шагов между ними.
enum AIChatFeedLayout {
    static func items(entries: [ChatEntry], reply: AIChatController.LiveReply?) -> [AIChatFeedItem] {
        var items: [AIChatFeedItem] = []
        var steps: [AIChatStep] = []
        var previous: ChatEntry?
        var lastStepDate: Date?

        func closeSteps(at end: Date?, isRunning: Bool = false) {
            guard !steps.isEmpty else { return }
            let seconds = both(previous?.createdAt, end ?? lastStepDate).map { start, end in Int(end.timeIntervalSince(start).rounded()) } ?? 0
            items.append(.steps(AIChatStepGroup(id: "steps-" + (previous?.id.uuidString ?? "start"), steps: steps,
                                                isRunning: isRunning, summary: AIChatStepGroup.summary(seconds: seconds))))
            steps = []
            lastStepDate = nil
        }

        for entry in entries {
            switch entry.kind {
            case .user:
                closeSteps(at: nil)
                items.append(.user(entry))
                previous = entry
            case .tool:
                steps.append(AIChatStep(kind: .tool, title: entry.title ?? entry.toolName ?? "", state: entry.ok == false ? .failed : .done))
                lastStepDate = entry.createdAt
            case .assistant:
                if let reasoning = entry.reasoning, !reasoning.isEmpty {
                    steps.append(AIChatStep(kind: .reasoning, title: AIChatStep.reasoningTitle, detail: reasoning, state: .done))
                    lastStepDate = entry.createdAt
                }
                guard isAnswer(entry) else { continue }
                closeSteps(at: entry.createdAt)
                items.append(.answer(entry))
                previous = entry
            }
        }

        guard let reply else {
            closeSteps(at: nil)
            return items
        }
        if !reply.text.isEmpty {
            if !reply.reasoning.isEmpty {
                steps.append(AIChatStep(kind: .reasoning, title: AIChatStep.reasoningTitle, detail: reply.reasoning, state: .done))
            }
            closeSteps(at: Date())
            items.append(.liveText(reply.text))
            return items
        }
        if !reply.reasoning.isEmpty {
            let state: AIChatStep.State = reply.runningTool == nil ? .running : .done
            steps.append(AIChatStep(kind: .reasoning, title: state == .running ? AIChatStep.thinkingTitle : AIChatStep.reasoningTitle,
                                    detail: reply.reasoning, state: state))
        }
        if let tool = reply.runningTool {
            steps.append(AIChatStep(kind: .tool, title: tool, state: .running))
        } else if reply.reasoning.isEmpty {
            steps.append(AIChatStep(kind: .reasoning, title: AIChatStep.thinkingTitle, state: .running))
        }
        closeSteps(at: nil, isRunning: true)
        return items
    }

    /// Запись, которую человек видит ответом. Ход модели только с вызовами инструментов — шаг, а не ответ.
    private static func isAnswer(_ entry: ChatEntry) -> Bool {
        !entry.text.isEmpty || entry.error != nil || entry.stopped == true
    }
}

private func both<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
    guard let a, let b else { return nil }
    return (a, b)
}
