import AIAgent
import AIChatHistory
import AIChatPanel
import AIModels
import Foundation
import UIGallery

/// Панель ИИ-агента в галерее (008): заготовленные чаты в базе, без запросов к моделям.
@MainActor
enum GalleryAIChatScene {
    private static let mainChat = UUID(uuidString: "0193a1b2-0000-7000-8000-00000000a1c1")!

    static func show(_ kind: GalleryAIChat, model: MainWindowModel, pageId: UUID) async -> String? {
        model.select(pageId)
        do { try seed(AIChatStore(store: model.store)) } catch { return "чаты не записались: \(error)" }
        try? await Task.sleep(for: .milliseconds(200))
        let chat = model.aiChat
        switch kind {
        case .empty: chat.newChat()
        case .toolReply: chat.openChat(mainChat)
        case .stepsExpanded:
            chat.openChat(mainChat)
            chat.expandAllSteps()
        case .modelMenu:
            chat.newChat()
            chat.popup = .models
        case .levelMenu:
            chat.newChat()
            chat.popup = .levels
        case .pastChats:
            chat.openChat(mainChat)
            chat.popup = .pastChats
        case .deleteMenu:
            chat.openChat(mainChat)
            chat.popup = .pastChats
            guard let row = chat.chatList.first(where: { $0.title == "Идеи для отпуска" }) else { return "нет прошлого чата" }
            chat.toggleChatMenu(row.id)
        }
        chat.isOpen = true
        if kind == .toolReply || kind == .stepsExpanded, chat.entries.count < 5 { return "чат не открылся" }
        try? await Task.sleep(for: .milliseconds(600))
        return nil
    }

    static func tearDown(model: MainWindowModel) {
        model.aiChat.newChat()
        model.aiChat.isOpen = false
    }

    /// Один чат с вызовами инструментов и несколько прошлых по срокам — один раз на базу галереи.
    private static func seed(_ chats: AIChatStore) throws {
        guard try chats.chat(mainChat) == nil else { return }
        let now = Date()
        let page = PageContext(pageID: "", title: "Планы", path: "Проекты/Планы", markdown: "", truncated: false)
        let read = ModelToolCall(id: "g1", name: "page_read", arguments: #"{"page":"current"}"#)
        var first = ChatEntry(createdAt: now.addingTimeInterval(2), kind: .assistant)
        first.reasoning = "Нужно прочитать страницу, выбрать дела с датами и оформить их задачами."
        first.toolCalls = [read]
        var second = ChatEntry(createdAt: now.addingTimeInterval(5), kind: .assistant)
        second.reasoning = "Дела нашлись в девяти абзацах — превращаю каждый в задачу со сроком."
        let edits = (1...9).map { ModelToolCall(id: "e\($0)", name: "block_update", arguments: "{}") }
        second.toolCalls = edits
        var answer = ChatEntry(createdAt: now.addingTimeInterval(18), kind: .assistant, text: """
        Готово. Превратил дела на странице в задачи со сроками и собрал их в начале раздела **«Задачи на неделю»**:

        - [ ] Созвон с командой — вторник
        - [ ] Черновик отчёта — среда
        - [ ] Купить билеты — пятница

        Остальные абзацы не трогал, а если нужно, могу расставить задачам ответственных и напоминания.
        """)
        answer.reasoning = "Список готов, коротко сообщаю, что изменилось."
        let editEntries = edits.enumerated().map { index, call in
            ChatEntry.tool(callID: call.id, name: call.name, outcome: ToolOutcome(ok: true, output: "{}"), title: NoteToolbox.title(for: call),
                           at: now.addingTimeInterval(6 + Double(index)))
        }
        let entries = [
            ChatEntry.user("Собери из этой страницы список задач на неделю", page: page, at: now),
            first,
            ChatEntry.tool(callID: read.id, name: read.name, outcome: ToolOutcome(ok: true, output: "{}"), title: NoteToolbox.title(for: read),
                           at: now.addingTimeInterval(3)),
            second,
        ] + editEntries + [answer]
        try chats.createChat(id: mainChat, title: "Собери из этой страницы список задач на неделю", at: now)
        for entry in entries { try chats.append(try ChatEntryCoding.encode(entry), id: entry.id, to: mainChat, at: entry.createdAt) }

        let past: [(String, Int)] = [("Перевод заметки о встрече", 1), ("Идеи для отпуска", 3), ("Книги на осень", 12), ("Итоги квартала", 40)]
        for (title, daysAgo) in past {
            let date = now.addingTimeInterval(-Double(daysAgo) * 86_400)
            let chat = try chats.createChat(title: title, at: date)
            let entry = ChatEntry.user(title, page: nil, at: date)
            try chats.append(try ChatEntryCoding.encode(entry), id: entry.id, to: chat.id, at: date)
        }
    }
}
