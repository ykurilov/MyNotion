import ControlProtocol
import Foundation
import Testing
@testable import AIModels

@Suite("Тело запроса к модели")
struct ChatCompletionBodyTests {
    private let deepSeek = ModelCatalog.deepSeekFlash.routes[0]
    private let deepSeekReserve = ModelCatalog.deepSeekFlash.routes[1]
    private let glm = ModelCatalog.glmFlash.routes[0]
    private let qwen = ModelCatalog.qwenFlash.routes[0]

    private let tool = ModelTool(name: "page_read", description: "Прочитать страницу",
                                 parameters: ["type": "object", "properties": ["page": ["type": "string"]], "required": ["page"]])

    private func request(level: ReasoningLevel, messages: [ModelMessage]? = nil) -> ModelRequest {
        ModelRequest(messages: messages ?? [.system("Ты помощник."), .user("Привет")], tools: [tool], level: level)
    }

    @Test("DeepSeek: модель, поток с расходом, рассуждения и сила, инструменты")
    func deepSeekBody() {
        let body = ChatCompletionBody.json(for: request(level: .high), route: deepSeek)
        #expect(body["model"] == "deepseek-flash")
        #expect(body["stream"] == true)
        #expect(body["stream_options"] == ["include_usage": true])
        #expect(body["thinking"] == ["type": "enabled"])
        #expect(body["reasoning_effort"] == "high")
        #expect(body["reasoning"] == nil)
        #expect(body["tools"] == [["type": "function", "function": ["name": "page_read", "description": "Прочитать страницу",
                                                                      "parameters": tool.parameters]]])
        #expect(body["messages"] == [["role": "system", "content": "Ты помощник."], ["role": "user", "content": "Привет"]])
    }

    @Test("DeepSeek без рассуждений: thinking выключен, силы нет")
    func deepSeekWithoutReasoning() {
        let body = ChatCompletionBody.json(for: request(level: .none), route: deepSeek)
        #expect(body["thinking"] == ["type": "disabled"])
        #expect(body["reasoning_effort"] == nil)
    }

    @Test("DeepSeek: рассуждения ответа с инструментами уходят обратно в reasoning_content")
    func deepSeekReasoningPassback() {
        let call = ModelToolCall(id: "call_1", name: "page_read", arguments: #"{"page":"a"}"#)
        let messages: [ModelMessage] = [.user("Что там?"), .assistant(text: "", reasoning: "Надо прочитать", toolCalls: [call]),
                                        .tool(callID: "call_1", content: "текст")]
        let body = ChatCompletionBody.json(for: request(level: .low, messages: messages), route: deepSeek)
        #expect(body["messages"]?[1] == ["role": "assistant", "content": nil, "reasoning_content": "Надо прочитать",
                                         "tool_calls": [["id": "call_1", "type": "function",
                                                         "function": ["name": "page_read", "arguments": #"{"page":"a"}"#]]]])
        #expect(body["messages"]?[2] == ["role": "tool", "tool_call_id": "call_1", "content": "текст"])
    }

    @Test("DeepSeek с рассуждениями: ход с инструментами без рассуждений уходит с пустым reasoning_content, иначе 400")
    func deepSeekEmptyReasoningPassback() {
        let call = ModelToolCall(id: "call_1", name: "page_read", arguments: "{}")
        let messages: [ModelMessage] = [.user("Что там?"), .assistant(text: "", reasoning: nil, toolCalls: [call]),
                                        .tool(callID: "call_1", content: "текст"), .assistant(text: "Готово", reasoning: nil, toolCalls: [])]
        let thinking = ChatCompletionBody.json(for: request(level: .high, messages: messages), route: deepSeek)
        #expect(thinking["messages"]?[1]?["reasoning_content"] == "")
        #expect(thinking["messages"]?[3]?["reasoning_content"] == nil, "Готовому ответу рассуждения не нужны")
        let plain = ChatCompletionBody.json(for: request(level: .none, messages: messages), route: deepSeek)
        #expect(plain["messages"]?[1]?["reasoning_content"] == nil)
        let reserve = ChatCompletionBody.json(for: request(level: .high, messages: messages), route: deepSeekReserve)
        #expect(reserve["messages"]?[1]?["reasoning"] == nil)
        #expect(reserve["messages"]?[1]?["reasoning_content"] == nil)
    }

    @Test("OpenRouter: сила рассуждений в reasoning.effort, рассуждения ответа — в reasoning")
    func openRouterEffort() {
        let messages: [ModelMessage] = [.user("Привет"), .assistant(text: "Здравствуйте", reasoning: "думаю", toolCalls: [])]
        let body = ChatCompletionBody.json(for: request(level: .medium, messages: messages), route: glm)
        #expect(body["model"] == "z-ai/glm-5.3-flash:nitro")
        #expect(body["reasoning"] == ["effort": "medium"])
        #expect(body["thinking"] == nil)
        #expect(body["reasoning_effort"] == nil)
        #expect(body["messages"]?[1] == ["role": "assistant", "content": "Здравствуйте", "reasoning": "думаю"])
    }

    @Test("OpenRouter для DeepSeek: «без рассуждений» выключает их, «максимум» — самая большая сила")
    func openRouterDeepSeekLevels() {
        #expect(ChatCompletionBody.json(for: request(level: .none), route: deepSeekReserve)["reasoning"] == ["enabled": false])
        #expect(ChatCompletionBody.json(for: request(level: .max), route: deepSeekReserve)["reasoning"] == ["effort": "xhigh"])
    }

    @Test("Qwen: рассуждения только включаются и выключаются")
    func qwenToggle() {
        #expect(ChatCompletionBody.json(for: request(level: .high), route: qwen)["reasoning"] == ["enabled": true])
        #expect(ChatCompletionBody.json(for: request(level: .none), route: qwen)["reasoning"] == ["enabled": false])
    }

    @Test("Без инструментов поля tools нет")
    func noTools() {
        let body = ChatCompletionBody.json(for: ModelRequest(messages: [.user("a")], tools: [], level: .none), route: deepSeek)
        #expect(body["tools"] == nil)
    }

    @Test("Начало тела одинаково, когда к чату добавляется новое сообщение, — модель берёт его из кэша")
    func stablePrefix() {
        let first = ChatCompletionBody.data(for: request(level: .high, messages: [.system("Инструкция"), .user("один")]), route: deepSeek)
        let second = ChatCompletionBody.data(for: request(level: .high, messages: [.system("Инструкция"), .user("один"),
                                                                                    .assistant(text: "ок", reasoning: nil, toolCalls: []),
                                                                                    .user("два")]), route: deepSeek)
        let firstText = String(decoding: first, as: UTF8.self)
        let secondText = String(decoding: second, as: UTF8.self)
        let marker = try! #require(firstText.range(of: "\"один\""))
        #expect(secondText.hasPrefix(String(firstText[..<marker.upperBound])))
    }

    @Test("Адрес и заголовки: ключ только в Authorization, у OpenRouter — название приложения")
    func urlRequest() throws {
        let direct = ModelRouteClient.urlRequest(for: request(level: .none), route: deepSeek, key: "k1")
        #expect(direct.url?.absoluteString == "https://api.deepseek.com/chat/completions")
        #expect(direct.httpMethod == "POST")
        #expect(direct.value(forHTTPHeaderField: "Authorization") == "Bearer k1")
        #expect(direct.value(forHTTPHeaderField: "Accept") == "text/event-stream")
        let reserve = ModelRouteClient.urlRequest(for: request(level: .none), route: glm, key: "k2")
        #expect(reserve.url?.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
        #expect(reserve.value(forHTTPHeaderField: "Authorization") == "Bearer k2")
        #expect(reserve.value(forHTTPHeaderField: "X-Title") == "MyNotion")
        let body = try #require(reserve.httpBody)
        #expect(!String(decoding: body, as: UTF8.self).contains("k2"))
    }
}
