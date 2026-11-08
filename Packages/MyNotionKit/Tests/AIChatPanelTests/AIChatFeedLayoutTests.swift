import AIAgent
import AIModels
import Foundation
import Testing
@testable import AIChatPanel

/// Раскладка ленты: шаги агента между сообщениями сворачиваются в одну строку-сводку.
@MainActor
struct AIChatFeedLayoutTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func user(_ text: String, at second: Double = 0) -> ChatEntry {
        .user(text, page: nil, at: start.addingTimeInterval(second))
    }

    private func assistant(text: String = "", reasoning: String? = nil, at second: Double = 0) -> ChatEntry {
        var entry = ChatEntry(createdAt: start.addingTimeInterval(second), kind: .assistant, text: text)
        entry.reasoning = reasoning
        return entry
    }

    private func tool(_ title: String, ok: Bool = true, at second: Double = 0) -> ChatEntry {
        var entry = ChatEntry(createdAt: start.addingTimeInterval(second), kind: .tool, text: "{}")
        entry.title = title
        entry.ok = ok
        return entry
    }

    private func groups(_ items: [AIChatFeedItem]) -> [AIChatStepGroup] {
        items.compactMap { if case .steps(let group) = $0 { group } else { nil } }
    }

    @Test func consecutiveStepsCollapseIntoOneGroupBeforeTheAnswer() throws {
        let entries = [
            user("Поправь страницу"),
            assistant(reasoning: "Сначала прочитаю", at: 1),
            tool("Читает открытую страницу", at: 2),
            assistant(reasoning: "Теперь правлю", at: 3),
        ] + (4...12).map { tool("Правит блок", at: Double($0)) } + [
            assistant(text: "Готово", reasoning: "Сообщаю итог", at: 14),
        ]
        let items = AIChatFeedLayout.items(entries: entries, reply: nil)

        try #require(items.count == 3)
        guard case .user = items[0], case .steps(let group) = items[1], case .answer(let answer) = items[2] else {
            Issue.record("ожидалось: сообщение, сводка шагов, ответ — пришло \(items)")
            return
        }
        #expect(answer.text == "Готово")
        #expect(group.steps.count == 13)
        #expect(group.steps.first == AIChatStep(kind: .reasoning, title: "Рассуждения", detail: "Сначала прочитаю", state: .done))
        #expect(group.steps[1] == AIChatStep(kind: .tool, title: "Читает открытую страницу", detail: nil, state: .done))
        #expect(group.steps.last?.detail == "Сообщаю итог")
        #expect(!group.isRunning)
        #expect(group.summary == "Работал 14 с")
    }

    @Test func eachTurnGetsItsOwnGroup() {
        let entries = [
            user("Раз"), tool("Читает открытую страницу", at: 2), assistant(text: "Ответ 1", at: 3),
            user("Два", at: 10), tool("Ищет «план»", at: 12), assistant(text: "Ответ 2", at: 13),
        ]
        let found = groups(AIChatFeedLayout.items(entries: entries, reply: nil))
        #expect(found.map(\.steps.count) == [1, 1])
        #expect(Set(found.map(\.id)).count == 2)
    }

    @Test func answerWithoutStepsHasNoGroup() {
        let items = AIChatFeedLayout.items(entries: [user("Привет"), assistant(text: "Здравствуйте", at: 1)], reply: nil)
        #expect(groups(items).isEmpty)
        #expect(items.count == 2)
    }

    @Test func failedToolMarksStepFailed() {
        let entries = [user("Сделай"), tool("Удаляет блок", ok: false, at: 1), assistant(text: "Не вышло", at: 2)]
        let group = groups(AIChatFeedLayout.items(entries: entries, reply: nil)).first
        #expect(group?.steps.first?.state == .failed)
    }

    @Test func liveTurnShowsCurrentStepInOpenGroup() {
        let entries = [user("Поправь"), assistant(reasoning: "Читаю", at: 1), tool("Читает открытую страницу", at: 2)]
        var reply = AIChatController.LiveReply()
        reply.runningTool = "Правит блок"
        let items = AIChatFeedLayout.items(entries: entries, reply: reply)

        #expect(items.count == 2)
        guard case .steps(let group) = items.last else { Issue.record("нет живой сводки: \(items)"); return }
        #expect(group.isRunning)
        #expect(group.current == AIChatStep(kind: .tool, title: "Правит блок", detail: nil, state: .running))
        #expect(group.steps.count == 3)
    }

    @Test func liveThinkingWithoutStepsIsCurrentStep() {
        let items = AIChatFeedLayout.items(entries: [user("Привет")], reply: AIChatController.LiveReply())
        guard case .steps(let group) = items.last else { Issue.record("нет живой сводки: \(items)"); return }
        #expect(group.current?.title == "Думает…")
        #expect(group.current?.state == .running)
    }

    @Test func liveTextClosesGroupAndFollowsIt() throws {
        var reply = AIChatController.LiveReply()
        reply.reasoning = "Итог"
        reply.text = "Готово, поправил"
        let entries = [user("Поправь"), tool("Правит блок", at: 2)]
        let items = AIChatFeedLayout.items(entries: entries, reply: reply)

        try #require(items.count == 3)
        guard case .steps(let group) = items[1], case .liveText(let text) = items[2] else {
            Issue.record("ожидалось: сводка и живой текст — пришло \(items)")
            return
        }
        #expect(!group.isRunning)
        #expect(group.steps.last?.detail == "Итог")
        #expect(text == "Готово, поправил")
    }

    /// Живая сводка не меняет id, когда ход закончился: раскрытая строка остаётся раскрытой.
    @Test func groupIdIsStableFromLiveToDone() {
        let entries = [user("Поправь"), tool("Правит блок", at: 2)]
        let live = groups(AIChatFeedLayout.items(entries: entries, reply: AIChatController.LiveReply())).first
        let done = groups(AIChatFeedLayout.items(entries: entries + [assistant(text: "Готово", at: 3)], reply: nil)).first
        #expect(live?.id != nil)
        #expect(live?.id == done?.id)
    }

    @Test func stoppedOrFailedAnswerEndsGroup() {
        var stopped = assistant(at: 3)
        stopped.stopped = true
        let items = AIChatFeedLayout.items(entries: [user("Сделай"), tool("Правит блок", at: 2), stopped], reply: nil)
        #expect(items.count == 3)
        if case .answer(let entry) = items.last { #expect(entry.stopped == true) } else { Issue.record("нет ответа: \(items)") }
    }

    @Test func summaryNamesMinutesForLongWork() {
        #expect(AIChatStepGroup.summary(seconds: 0) == "Работал 1 с")
        #expect(AIChatStepGroup.summary(seconds: 59) == "Работал 59 с")
        #expect(AIChatStepGroup.summary(seconds: 60) == "Работал 1 мин")
        #expect(AIChatStepGroup.summary(seconds: 83) == "Работал 1 мин 23 с")
    }
}
