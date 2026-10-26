import Foundation
import Synchronization
import Testing
@testable import NotionAPI

/// Картинка блока Notion по ключу интеграции: сеть подменная, ключ и адреса — выдуманные.
@Suite("Notion API: картинка блока и проверка ключа")
struct NotionClientTests {
    private static let blockId = UUID(uuidString: "3C90C3CC-0D44-4B50-8888-8DD25736052A")!
    private static let fileURL = URL(string: "https://files.example.com/secure/photo.png?X-Amz-Signature=abc")!

    /// Подменная сеть: ответы по адресу, запросы записываются.
    final class FakeNetwork: Sendable {
        let requests = Mutex<[URLRequest]>([])
        let respond: @Sendable (URLRequest) throws -> (Int, Data, String?)

        init(_ respond: @escaping @Sendable (URLRequest) throws -> (Int, Data, String?)) {
            self.respond = respond
        }

        var send: NotionClient.Send {
            { request in
                self.requests.withLock { $0.append(request) }
                let (status, data, mime) = try self.respond(request)
                var headers: [String: String] = [:]
                if let mime { headers["Content-Type"] = mime }
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
                return (data, response)
            }
        }
    }

    private static func blockJSON(_ image: String) -> Data {
        Data(#"{"object":"block","id":"3c90c3cc-0d44-4b50-8888-8dd25736052a","type":"image","image":\#(image)}"#.utf8)
    }

    private static let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])

    private func client(key: String? = "test-key", _ network: FakeNetwork) -> NotionClient {
        NotionClient(key: { key }, send: network.send)
    }

    @Test("Блок с файлом Notion: запрос блока с ключом и версией API, файл — по временной ссылке без ключа")
    func notionHostedImage() async throws {
        let network = FakeNetwork { request in
            if request.url?.host == "api.notion.com" {
                return (200, Self.blockJSON(#"{"type":"file","file":{"url":"\#(Self.fileURL)","expiry_time":"2026-10-26T12:00:00.000Z"}}"#), "application/json")
            }
            return (200, Self.png, "image/png")
        }

        let image = try await client(network).image(ofBlock: Self.blockId)

        #expect(image.data == Self.png)
        #expect(image.contentType == "image/png")
        #expect(image.fileName == "photo.png")
        let requests = network.requests.withLock { $0 }
        #expect(requests.count == 2)
        #expect(requests[0].url?.absoluteString == "https://api.notion.com/v1/blocks/3c90c3cc-0d44-4b50-8888-8dd25736052a")
        #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        #expect(requests[0].value(forHTTPHeaderField: "Notion-Version") == NotionClient.version)
        #expect(requests[1].url == Self.fileURL)
        #expect(requests[1].value(forHTTPHeaderField: "Authorization") == nil, "Ключ Notion не уходит на чужой адрес")
    }

    @Test("Картинка по внешней ссылке: та же схема, адрес из `external`")
    func externalImage() async throws {
        let external = URL(string: "https://images.example.org/cat.jpg")!
        let network = FakeNetwork { request in
            request.url?.host == "api.notion.com"
                ? (200, Self.blockJSON(#"{"type":"external","external":{"url":"\#(external)"}}"#), "application/json")
                : (200, Self.png, "image/jpeg")
        }

        let image = try await client(network).image(ofBlock: Self.blockId)

        #expect(network.requests.withLock { $0.last?.url } == external)
        #expect(image.fileName == "cat.jpg")
    }

    @Test("Нет ключа — сразу ошибка «нет ключа», в сеть не ходит")
    func missingKey() async throws {
        let network = FakeNetwork { _ in (200, Data(), nil) }
        await #expect(throws: NotionAPIError.missingKey) { try await client(key: nil, network).image(ofBlock: Self.blockId) }
        await #expect(throws: NotionAPIError.missingKey) { try await client(key: "  ", network).image(ofBlock: Self.blockId) }
        #expect(network.requests.withLock { $0.isEmpty })
    }

    @Test("Ответы Notion — понятные ошибки: ключ не подошёл, нет доступа к странице, подождать, Notion не отвечает")
    func statusErrors() async throws {
        let cases: [(Int, String, NotionAPIError)] = [
            (401, "unauthorized", .badKey),
            (403, "restricted_resource", .noAccess),
            (404, "object_not_found", .noAccess),
            (429, "rate_limited", .rateLimited),
            (503, "service_unavailable", .unavailable),
        ]
        for (status, code, expected) in cases {
            let network = FakeNetwork { _ in
                (status, Data(#"{"object":"error","status":\#(status),"code":"\#(code)","message":"…"}"#.utf8), "application/json")
            }
            await #expect(throws: expected) { try await client(network).image(ofBlock: Self.blockId) }
        }
    }

    @Test("Блок не картинка или без ссылки — «Notion не отдал картинку»; файл не скачался — своя ошибка")
    func notAnImage() async throws {
        let paragraph = FakeNetwork { _ in (200, Data(#"{"object":"block","type":"paragraph","paragraph":{}}"#.utf8), "application/json") }
        await #expect(throws: NotionAPIError.notImage) { try await client(paragraph).image(ofBlock: Self.blockId) }

        let expiredLink = FakeNetwork { request in
            request.url?.host == "api.notion.com"
                ? (200, Self.blockJSON(#"{"type":"file","file":{"url":"\#(Self.fileURL)"}}"#), "application/json")
                : (403, Data("<Error>AccessDenied</Error>".utf8), "application/xml")
        }
        await #expect(throws: NotionAPIError.downloadFailed) { try await client(expiredLink).image(ofBlock: Self.blockId) }

        let html = FakeNetwork { request in
            request.url?.host == "api.notion.com"
                ? (200, Self.blockJSON(#"{"type":"file","file":{"url":"\#(Self.fileURL)"}}"#), "application/json")
                : (200, Data("<html>вход</html>".utf8), "text/html")
        }
        await #expect(throws: NotionAPIError.notImage) { try await client(html).image(ofBlock: Self.blockId) }
    }

    @Test("Нет сети и долгое ожидание — свои ошибки; больше 100 МБ — «слишком большой»")
    func networkErrors() async throws {
        let offline = FakeNetwork { _ in throw URLError(.notConnectedToInternet) }
        await #expect(throws: NotionAPIError.offline) { try await client(offline).image(ofBlock: Self.blockId) }
        let slow = FakeNetwork { _ in throw URLError(.timedOut) }
        await #expect(throws: NotionAPIError.timedOut) { try await client(slow).image(ofBlock: Self.blockId) }

        let big = FakeNetwork { request in
            request.url?.host == "api.notion.com"
                ? (200, Self.blockJSON(#"{"type":"file","file":{"url":"\#(Self.fileURL)"}}"#), "application/json")
                : (200, Data(count: 11), "image/png")
        }
        let limited = NotionClient(key: { "test-key" }, send: big.send, byteLimit: 10)
        await #expect(throws: NotionAPIError.tooLarge) { try await limited.image(ofBlock: Self.blockId) }
    }

    @Test("Сообщения — что случилось и что сделать")
    func messages() {
        #expect(NotionAPIError.missingKey.errorDescription?.contains("Настройк") == true)
        #expect(NotionAPIError.noAccess.errorDescription?.contains("Подключения") == true)
        #expect(NotionAPIError.offline.errorDescription?.contains("интернет") == true)
        for error in [NotionAPIError.missingKey, .badKey, .noAccess, .rateLimited, .offline, .timedOut, .notImage, .downloadFailed,
                      .tooLarge, .unavailable] {
            #expect(!(error.errorDescription ?? "").isEmpty)
        }
    }

    @Test("«Проверить» ключ: GET /v1/users/me с этим ключом; 401 — ключ не подошёл")
    func checkKey() async throws {
        let ok = FakeNetwork { _ in (200, Data(#"{"object":"user","type":"bot"}"#.utf8), "application/json") }
        try await client(key: nil, ok).checkKey(" typed-key ")
        let request = try #require(ok.requests.withLock { $0.first })
        #expect(request.url?.absoluteString == "https://api.notion.com/v1/users/me")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer typed-key")

        let bad = FakeNetwork { _ in (401, Data(#"{"object":"error","code":"unauthorized"}"#.utf8), "application/json") }
        await #expect(throws: NotionAPIError.badKey) { try await client(bad).checkKey("wrong") }
        await #expect(throws: NotionAPIError.missingKey) { try await client(bad).checkKey("") }
    }

    @Test("Ссылка на блок Notion: `notion-block:<id>` туда и обратно; чужие ссылки — не блок")
    func blockLink() {
        let url = NotionBlockLink.url(forBlock: Self.blockId)
        #expect(url.scheme == NotionBlockLink.scheme)
        #expect(NotionBlockLink.blockId(from: url) == Self.blockId)
        #expect(NotionBlockLink.blockId(from: URL(string: "https://notion.so/x")!) == nil)
        #expect(NotionBlockLink.blockId(from: URL(string: "notion-block:не-uuid")!) == nil)
    }
}
