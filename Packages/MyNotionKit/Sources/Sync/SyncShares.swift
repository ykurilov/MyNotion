import Foundation

/// Ссылка на страницу только для чтения (specs/006-share-link/contracts/share-api.md). Состояние живёт на сервере:
/// его видят все Mac Юрия.
public struct SyncShare: Sendable, Hashable, Codable {
    public let pageId: UUID
    /// 32 случайных байта base64url: адрес `<сервер>/s/<token>`.
    public let token: String
    public let enabled: Bool
    public let includeSubpages: Bool
    /// SHA-256 опубликованного снимка; `nil` — снимка нет.
    public let digest: String?
    /// Когда положен снимок, мс от 1970.
    public let publishedAt: Int?

    public init(pageId: UUID, token: String, enabled: Bool, includeSubpages: Bool, digest: String?, publishedAt: Int?) {
        self.pageId = pageId
        self.token = token
        self.enabled = enabled
        self.includeSubpages = includeSubpages
        self.digest = digest
        self.publishedAt = publishedAt
    }

    /// Адрес страницы в браузере.
    public func url(on server: URL) -> URL {
        server.appendingPathComponent("s").appendingPathComponent(token)
    }
}

/// Управление ссылками и публикация снимка — с токеном устройства.
public protocol SyncShareTransport: Sendable {
    func shares() async throws -> [SyncShare]
    /// Первое включение создаёт ссылку; повторное — та же ссылка; выключение стирает снимок и файлы на сервере.
    func setShare(_ pageId: UUID, enabled: Bool, includeSubpages: Bool?) async throws -> SyncShare
    /// Новая ссылка: старая сразу перестаёт открываться.
    func rotateShare(_ pageId: UUID) async throws -> SyncShare
    func deleteShare(_ pageId: UUID) async throws
    /// Снимок страницы (JSON); ответ — файлы снимка, которых на сервере ещё нет.
    func publishShare(_ pageId: UUID, digest: String, document: Data) async throws -> [UUID]
    func putShareFile(_ pageId: UUID, fileId: UUID, contentsOf url: URL) async throws
}

extension HTTPSyncTransport: SyncShareTransport {
    func shares() async throws -> [SyncShare] {
        struct Answer: Decodable { let items: [SyncShare] }
        let answer: Answer = try await send("GET", "shares")
        return answer.items
    }

    func setShare(_ pageId: UUID, enabled: Bool, includeSubpages: Bool?) async throws -> SyncShare {
        struct Body: Encodable { let enabled: Bool; let includeSubpages: Bool? }
        return try await send("PUT", "shares/\(pageId.shareKey)", body: Body(enabled: enabled, includeSubpages: includeSubpages))
    }

    func rotateShare(_ pageId: UUID) async throws -> SyncShare {
        try await send("POST", "shares/\(pageId.shareKey)/rotate", body: [String: String]())
    }

    func deleteShare(_ pageId: UUID) async throws {
        let _: Ignored = try await send("DELETE", "shares/\(pageId.shareKey)")
    }

    func publishShare(_ pageId: UUID, digest: String, document: Data) async throws -> [UUID] {
        struct Answer: Decodable { let missingFiles: [UUID] }
        // снимок вставляется как есть: те же байты, что посчитаны в digest
        var body = Data(#"{"digest":""#.utf8)
        body.append(Data(digest.utf8))
        body.append(Data(#"","document":"#.utf8))
        body.append(document)
        body.append(Data("}".utf8))
        var request = try makeRequest("PUT", "shares/\(pageId.shareKey)/document")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Self.error(status: status, data: data) }
        return try JSONDecoder().decode(Answer.self, from: data).missingFiles
    }

    func putShareFile(_ pageId: UUID, fileId: UUID, contentsOf url: URL) async throws {
        var request = try makeRequest("PUT", "shares/\(pageId.shareKey)/files/\(fileId.shareKey)")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.upload(for: request, fromFile: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Self.error(status: status, data: data) }
    }
}

extension UUID {
    /// Как id в адресах и снимке ссылок: строчными буквами.
    fileprivate var shareKey: String { uuidString.lowercased() }
}
