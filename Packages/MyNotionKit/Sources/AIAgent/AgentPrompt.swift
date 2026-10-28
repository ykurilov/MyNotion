import AIModels
import Foundation

/// Запрос к модели из записей чата. Порядок под кэш поставщика: неизменная инструкция, инструменты (их порядок
/// постоянный, `NoteToolbox.tools`), затем записи как есть. Открытая страница лежит внутри сообщения, к которому её
/// приложили, поэтому новое сообщение только дописывает запрос и не меняет его начало.
public enum AgentPrompt {
    public static let systemInstruction = """
    Ты — ИИ-агент в MyNotion, приложении заметок на Mac. Помогаешь человеку с его страницами и базами: читаешь, ищешь, \
    пишешь, правишь, переносишь, наводишь порядок.

    Как работать:
    - К сообщению человека приложена страница, открытая у него в этот момент (<открытая_страница>). «Эта страница», \
    «здесь», «тут» — про неё.
    - Делай сам, инструментами, не спрашивая разрешения. Уточняй, только если просьбу можно понять по-разному и результат \
    заметно различается.
    - Перед правкой существующей страницы прочитай её свежий текст. Меняй только то, о чём просят, остальное сохраняй.
    - Страницу указывают id, путём из названий через «/» или словом current — открытая страница. id из ответов \
    инструментов надёжнее названий.
    - Страницы удаляются только в корзину (page_trash). Удалить навсегда нельзя.
    - Отвечай по-русски, коротко и по делу, в Markdown. Если что-то изменил, скажи одной-двумя фразами, что именно.
    """

    /// Ответ на вызов, оставшийся без результата: поставщики отклоняют запрос с вызовом без ответа.
    static let notExecutedOutput = "Не выполнено: человек остановил ответ."

    public static func messages(for entries: [ChatEntry]) -> [ModelMessage] {
        var messages: [ModelMessage] = [.system(systemInstruction)]
        var pendingCalls: [String] = []

        func closePendingCalls() {
            for callID in pendingCalls { messages.append(.tool(callID: callID, content: notExecutedOutput)) }
            pendingCalls = []
        }

        for entry in entries {
            switch entry.kind {
            case .user:
                closePendingCalls()
                messages.append(.user(userContent(entry)))
            case .assistant:
                closePendingCalls()
                let calls = entry.toolCalls ?? []
                guard !entry.text.isEmpty || !calls.isEmpty else { continue }
                // DeepSeek требует вернуть рассуждения хода с инструментами; в готовом ответе они только тратят место.
                messages.append(.assistant(text: entry.text, reasoning: calls.isEmpty ? nil : entry.reasoning, toolCalls: calls))
                pendingCalls = calls.map(\.id)
            case .tool:
                guard let callID = entry.callID, let position = pendingCalls.firstIndex(of: callID) else { continue }
                pendingCalls.remove(at: position)
                messages.append(.tool(callID: callID, content: entry.text))
            }
        }
        closePendingCalls()
        return messages
    }

    static func userContent(_ entry: ChatEntry) -> String {
        guard let page = entry.page else { return entry.text }
        let attributes = "id=\"\(page.pageID)\" путь=\"\(page.path)\" название=\"\(page.title)\""
        let body: String
        if page.unchanged {
            body = "Та же страница, текст не менялся с прошлого сообщения."
        } else {
            body = page.markdown + (page.truncated ? "\n…(текст обрезан; целиком — page_read)" : "")
        }
        return "<открытая_страница \(attributes)>\n\(body)\n</открытая_страница>\n\n\(entry.text)"
    }
}
