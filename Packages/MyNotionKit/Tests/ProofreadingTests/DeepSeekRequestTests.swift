import Foundation
import NotesCore
import Testing
@testable import Proofreading

@Suite("Запрос к DeepSeek")
struct DeepSeekRequestTests {
    private func json(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("Тело: модель, системная инструкция первой, текст последним, рассуждения выключены, лишних полей нет")
    func body() throws {
        let body = try json(DeepSeekRequest.body(for: "превет"))
        #expect(Set(body.keys) == ["model", "messages", "thinking", "temperature"])
        #expect(body["model"] as? String == "deepseek-flash")
        #expect((body["thinking"] as? [String: String]) == ["type": "disabled"])
        #expect(body["temperature"] as? Double == 0)
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages.count == 2)
        #expect(messages[0] == ["role": "system", "content": DeepSeekRequest.systemInstruction])
        #expect(messages[1] == ["role": "user", "content": "превет"])
    }

    @Test("Начало запроса одинаково для любого текста — DeepSeek берёт его из кэша")
    func stablePrefix() throws {
        let first = String(decoding: DeepSeekRequest.body(for: "ЩЩЩ первый"), as: UTF8.self)
        let second = String(decoding: DeepSeekRequest.body(for: "совсем другой текст"), as: UTF8.self)
        let userText = try #require(first.range(of: "ЩЩЩ"))
        // Инструкция целиком — до текста пользователя.
        #expect(first[..<userText.lowerBound].contains(DeepSeekRequest.systemInstruction.prefix(40)))
        #expect(second.hasPrefix(String(first[..<userText.lowerBound])))
    }

    @Test("Инструкция: только орфография, пунктуация, грамматика; ё не навязывать; язык и метки сохранить; без пояснений")
    func instruction() {
        let text = DeepSeekRequest.systemInstruction
        for part in ["орфографию, пунктуацию и грамматику", "«ё» не навязывай", "Ничего не переводи", "⟦1⟧", "без пояснений", "переводы строк"] {
            #expect(text.contains(part), "Нет «\(part)»")
        }
    }

    @Test("Заголовки и адрес: POST, ключ в Authorization, ожидание 30 с")
    func urlRequest() {
        let request = DeepSeekRequest.urlRequest(text: "a", key: "test-key")
        #expect(request.url?.absoluteString == "https://api.deepseek.com/chat/completions")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.timeoutInterval == 30)
    }

    @Test("Ответ: текст первого варианта; обёртка ``` снимается")
    func parse() throws {
        let data = Data(#"{"choices":[{"index":0,"message":{"role":"assistant","content":"Привет, как дела?"},"finish_reason":"stop"}]}"#.utf8)
        #expect(try DeepSeekRequest.correctedText(from: data) == "Привет, как дела?")
        let fenced = Data(#"{"choices":[{"message":{"content":"```\nПривет\n```"},"finish_reason":"stop"}]}"#.utf8)
        #expect(try DeepSeekRequest.correctedText(from: fenced) == "Привет")
    }

    @Test("Обрезанный, пустой и непонятный ответ — понятная ошибка", arguments: [
        #"{"choices":[{"message":{"content":"Прив"},"finish_reason":"length"}]}"#,
        #"{"choices":[{"message":{"content":"  "},"finish_reason":"stop"}]}"#,
        #"{"choices":[]}"#,
        "<html>",
    ])
    func badResponse(text: String) {
        #expect(throws: ProofreadingError.badResponse) { try DeepSeekRequest.correctedText(from: Data(text.utf8)) }
    }

    @Test("Коды ответа → ошибки по-русски")
    func statuses() {
        #expect(DeepSeekRequest.error(forStatus: 200) == nil)
        #expect(DeepSeekRequest.error(forStatus: 401) == .invalidKey)
        #expect(DeepSeekRequest.error(forStatus: 402) == .insufficientBalance)
        #expect(DeepSeekRequest.error(forStatus: 429) == .rateLimited)
        #expect(DeepSeekRequest.error(forStatus: 503) == .server(status: 503))
        #expect(ProofreadingError.missingKey.errorDescription == "Нет ключа DeepSeek — добавьте его в Настройках")
        #expect(ProofreadingError.noConnection.errorDescription == "Нет связи с DeepSeek — проверьте интернет")
    }
}

@Suite("Исправитель DeepSeek")
struct DeepSeekProofreaderTests {
    private static func reply(_ status: Int, _ body: String = "") -> DeepSeekProofreader.Send {
        { request in
            (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    @Test("Без ключа запрос не уходит")
    func missingKey() async {
        let proofreader = DeepSeekProofreader(apiKey: { nil }, send: { _ in Issue.record("Запрос ушёл"); throw URLError(.unknown) })
        await #expect(throws: ProofreadingError.missingKey) { try await proofreader.proofread("текст") }
        let blank = DeepSeekProofreader(apiKey: { "  \n" }, send: Self.reply(200))
        await #expect(throws: ProofreadingError.missingKey) { try await blank.proofread("текст") }
    }

    @Test("Удачный ответ — исправленный текст; ключ из хранилища идёт в заголовок")
    func success() async throws {
        let proofreader = DeepSeekProofreader(apiKey: { "k-1\n" }, send: { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer k-1")
            return try await Self.reply(200, #"{"choices":[{"message":{"content":"Привет"},"finish_reason":"stop"}]}"#)(request)
        })
        #expect(try await proofreader.proofread("Превет") == "Привет")
    }

    @Test("Отказ API и сбой сети — понятные ошибки, отмена — отмена")
    func failures() async {
        await #expect(throws: ProofreadingError.invalidKey) { try await DeepSeekProofreader(apiKey: { "k" }, send: Self.reply(401)).proofread("а") }
        let offline = DeepSeekProofreader(apiKey: { "k" }, send: { _ in throw URLError(.notConnectedToInternet) })
        await #expect(throws: ProofreadingError.noConnection) { try await offline.proofread("а") }
        let slow = DeepSeekProofreader(apiKey: { "k" }, send: { _ in throw URLError(.timedOut) })
        await #expect(throws: ProofreadingError.timeout) { try await slow.proofread("а") }
        let cancelled = DeepSeekProofreader(apiKey: { "k" }, send: { _ in throw URLError(.cancelled) })
        await #expect(throws: CancellationError.self) { try await cancelled.proofread("а") }
    }

    @Test("Слишком длинный текст не отправляется")
    func tooLong() async {
        let proofreader = DeepSeekProofreader(apiKey: { "k" }, send: Self.reply(200))
        await #expect(throws: ProofreadingError.tooLong) {
            try await proofreader.proofread(String(repeating: "а", count: DeepSeekRequest.maximumLength + 1))
        }
    }

    @Test("Проверка ключа — список моделей")
    func checkKey() async throws {
        let proofreader = DeepSeekProofreader(apiKey: { nil }, send: { request in
            #expect(request.url == DeepSeekRequest.modelsEndpoint)
            return try await Self.reply(200, "{}")(request)
        })
        try await proofreader.checkKey("k")
        await #expect(throws: ProofreadingError.invalidKey) { try await DeepSeekProofreader(apiKey: { nil }, send: Self.reply(401)).checkKey("k") }
    }
}

/// Настоящий DeepSeek: только с ключом в `MYNOTION_DEEPSEEK_KEY` (живая проверка, не в обычном прогоне).
@Suite("DeepSeek вживую", .enabled(if: ProcessInfo.processInfo.environment["MYNOTION_DEEPSEEK_KEY"]?.isEmpty == false))
struct DeepSeekLiveTests {
    private let proofreader = DeepSeekProofreader(apiKey: { ProcessInfo.processInfo.environment["MYNOTION_DEEPSEEK_KEY"] })

    @Test("Исправляет ошибки и сохраняет метки, переводы строк и язык")
    func live() async throws {
        let segments = [InlineText("Превет, как дила? Я видел ⟦X⟧ вчера"), InlineText("this sentense have a error")]
        let source = ProofreadText(segments: segments.map(InlineTextFixture.replacingMarker))
        let started = Date()
        let corrected = try await proofreader.proofread(source.source)
        let elapsed = Date().timeIntervalSince(started)
        print("DeepSeek вживую: \(String(format: "%.2f", elapsed)) с\n\(source.source)\n→\n\(corrected)")
        let pieces = try source.apply(corrected)
        #expect(pieces.count == 2)
        #expect(pieces[0].string.contains("Привет"))
        #expect(pieces[0].string.contains("дела"))
        #expect(pieces[0].runs.contains { $0.style.isAtom }, "Упоминание на месте")
        #expect(pieces[1].string.contains("sentence"))
        #expect(elapsed < 15)
    }

    @Test("Правильный текст возвращается без изменений")
    func clean() async throws {
        let source = ProofreadText(segments: [InlineText("Сегодня хорошая погода, и мы идём гулять.")])
        let corrected = try await proofreader.proofread(source.source)
        #expect(!source.hasChanges(corrected), "Модель поменяла: \(corrected)")
    }

    @Test("Ключ проходит проверку")
    func key() async throws {
        try await proofreader.checkKey(ProcessInfo.processInfo.environment["MYNOTION_DEEPSEEK_KEY"] ?? "")
    }
}
