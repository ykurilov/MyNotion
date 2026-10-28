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
        if kind == .toolReply, chat.entries.count < 5 { return "чат не открылся" }
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
        let append = ModelToolCall(id: "g2", name: "page_append", arguments: "{\"page\":\"current\",\"markdown\":\"## Задачи на неделю\"}")
        var first = ChatEntry(createdAt: now, kind: .assistant)
        first.reasoning = "Нужно прочитать страницу, выбрать дела с датами и дописать их списком в конец."
        first.toolCalls = [read]
        var second = ChatEntry(createdAt: now, kind: .assistant)
        second.toolCalls = [append]
        var answer = ChatEntry(createdAt: now, kind: .assistant, text: """
        Готово. Дописал в конец страницы раздел **«Задачи на неделю»**:

        - [ ] Созвон с командой — вторник
        - [ ] Черновик отчёта — среда
        - [ ] Купить билеты — пятница
        """)
        answer.reasoning = "Список дописан, коротко сообщаю, что изменилось."
        let entries = [
            ChatEntry.user("Собери из этой страницы список задач на неделю", page: page, at: now),
            first,
            ChatEntry.tool(callID: read.id, name: read.name, outcome: ToolOutcome(ok: true, output: "{}"), title: NoteToolbox.title(for: read), at: now),
            second,
            ChatEntry.tool(callID: append.id, name: append.name, outcome: ToolOutcome(ok: true, output: "{}"), title: NoteToolbox.title(for: append), at: now),
            answer,
        ]
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
