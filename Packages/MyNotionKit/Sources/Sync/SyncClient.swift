import Foundation

// Клиент сервера синхронизации по contracts/sync-api.md. Сервер видит только зашифрованные пачки.

public struct SyncJournalItem: Sendable, Hashable, Codable {
    public let seq: Int
    public let batchId: String
    public let deviceId: String
    public let ciphertext: String

    public init(seq: Int, batchId: String, deviceId: String, ciphertext: String) {
        self.seq = seq
        self.batchId = batchId
        self.deviceId = deviceId
        self.ciphertext = ciphertext
    }
}

public struct SyncChangesPage: Sendable, Hashable, Codable {
    public let items: [SyncJournalItem]
    public let hasMore: Bool

    public init(items: [SyncJournalItem], hasMore: Bool) {
        self.items = items
        self.hasMore = hasMore
    }
}

public struct SyncSnapshotEnvelope: Sendable, Hashable, Codable {
    public let seq: Int
    public let ciphertext: String

    public init(seq: Int, ciphertext: String) {
        self.seq = seq
        self.ciphertext = ciphertext
    }
}

public struct SyncDevice: Sendable, Hashable, Codable, Identifiable {
    public let deviceId: String
    public let deviceName: String
    public let lastSeenAt: Date?
    public let lastAckSeq: Int

    public var id: String { deviceId }

    public init(deviceId: String, deviceName: String, lastSeenAt: Date?, lastAckSeq: Int) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.lastSeenAt = lastSeenAt
        self.lastAckSeq = lastAckSeq
    }
}

public struct SyncInvite: Sendable, Hashable, Codable {
    public let inviteCode: String
    public let expiresAt: Date

    public init(inviteCode: String, expiresAt: Date) {
        self.inviteCode = inviteCode
        self.expiresAt = expiresAt
    }
}

public struct SyncJoinResult: Sendable, Hashable, Codable {
    public let deviceId: String
    public let deviceToken: String
    public let latestSnapshotSeq: Int?

    public init(deviceId: String, deviceToken: String, latestSnapshotSeq: Int?) {
        self.deviceId = deviceId
        self.deviceToken = deviceToken
        self.latestSnapshotSeq = latestSnapshotSeq
    }
}

/// Ошибки сервера: единый вид `{"error":"<код>","message":"…"}`.
public enum SyncServerError: Error, Equatable, LocalizedError {
    case unauthorized
    case inviteExpired
    case tooLarge
    /// Журнал до запрошенного номера сжат: сначала снимок.
    case logCompacted(snapshotSeq: Int)
    case notFound
    case badRequest(String)
    case server(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized: "Этот Mac отключён от синхронизации или токен не подходит"
        case .inviteExpired: "Код подключения просрочен или уже использован — получите новый на первом Mac"
        case .tooLarge: "Пачка изменений слишком большая для сервера"
        case .logCompacted: "Журнал на сервере сжат — нужен снимок"
        case .notFound: "На сервере этого нет"
        case .badRequest(let message), .server(let message): message
        }
    }
}

/// Запросы одного устройства (с его токеном).
public protocol SyncTransport: Sendable {
    func postChanges(batchId: String, ciphertext: String) async throws -> Int
    /// Пачки новее `after`; если их нет — ждёт до `wait` секунд.
    func changes(after: Int, wait: Int) async throws -> SyncChangesPage
    func ack(_ seq: Int) async throws
    func putSnapshot(seq: Int, ciphertext: String) async throws
    func snapshot() async throws -> SyncSnapshotEnvelope?
    func devices() async throws -> [SyncDevice]
    func invite() async throws -> SyncInvite
    func deleteDevice(_ deviceId: String) async throws
}

/// Сервер: подключение нового устройства без токена и запросы с токеном.
public protocol SyncServer: Sendable {
    func join(inviteCode: String, deviceName: String) async throws -> SyncJoinResult
    func transport(deviceToken: String) -> any SyncTransport
}

/// Сервер по HTTPS (в тестах — локальный по HTTP).
public struct HTTPSyncServer: SyncServer {
    public let url: URL
    let session: URLSession

    public init(url: URL, session: URLSession = HTTPSyncServer.session) {
        self.url = url
        self.session = session
    }

    /// Долгое ожидание держит запрос до 25 с — таймаут с запасом.
    public static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 40
        configuration.timeoutIntervalForResource = 600
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: configuration)
    }()

    public func join(inviteCode: String, deviceName: String) async throws -> SyncJoinResult {
        let client = HTTPSyncTransport(baseURL: url, token: nil, session: session)
        return try await client.send("POST", "devices/join", body: ["inviteCode": inviteCode, "deviceName": deviceName])
    }

    public func transport(deviceToken: String) -> any SyncTransport {
        HTTPSyncTransport(baseURL: url, token: deviceToken, session: session)
    }
}

struct HTTPSyncTransport: SyncTransport {
    let baseURL: URL
    let token: String?
    let session: URLSession

    func postChanges(batchId: String, ciphertext: String) async throws -> Int {
        struct Answer: Decodable { let seq: Int }
        let answer: Answer = try await send("POST", "changes", body: ["batchId": batchId, "ciphertext": ciphertext])
        return answer.seq
    }

    func changes(after: Int, wait: Int) async throws -> SyncChangesPage {
        try await send("GET", "changes", query: ["after": "\(after)", "wait": "\(max(0, min(wait, 25)))"])
    }

    func ack(_ seq: Int) async throws {
        let _: Ignored = try await send("POST", "ack", body: ["seq": seq])
    }

    func putSnapshot(seq: Int, ciphertext: String) async throws {
        let _: Ignored = try await send("PUT", "snapshot", body: SyncSnapshotEnvelope(seq: seq, ciphertext: ciphertext))
    }

    func snapshot() async throws -> SyncSnapshotEnvelope? {
        do {
            return try await send("GET", "snapshot")
        } catch SyncServerError.notFound {
            return nil
        }
    }

    func devices() async throws -> [SyncDevice] {
        try await send("GET", "devices")
    }

    func invite() async throws -> SyncInvite {
        try await send("POST", "devices/invite", body: [String: String]())
    }

    func deleteDevice(_ deviceId: String) async throws {
        let _: Ignored = try await send("DELETE", "devices/\(deviceId)")
    }

    // MARK: Запрос

    private struct Ignored: Decodable {
        init(from decoder: any Decoder) throws {}
        init() {}
    }

    private struct ErrorBody: Decodable {
        let error: String
        let message: String?
        let snapshotSeq: Int?
    }

    func send<Answer: Decodable>(_ method: String, _ path: String, query: [String: String] = [:],
                                 body: (any Encodable)? = nil) async throws -> Answer {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(AnyEncodable(body))
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Self.error(status: status, data: data) }
        if Answer.self == Ignored.self || data.isEmpty { return try SyncJSON.decoder().decode(Answer.self, from: Data("{}".utf8)) }
        return try SyncJSON.decoder().decode(Answer.self, from: data)
    }

    private static func error(status: Int, data: Data) -> SyncServerError {
        let body = try? JSONDecoder().decode(ErrorBody.self, from: data)
        let message = body?.message ?? "Сервер ответил кодом \(status)"
        switch (status, body?.error) {
        case (401, _), (_, "unauthorized"): return .unauthorized
        case (410, "log_compacted"): return .logCompacted(snapshotSeq: body?.snapshotSeq ?? 0)
        case (410, _), (_, "invite_expired"): return .inviteExpired
        case (413, _), (_, "too_large"): return .tooLarge
        case (404, _): return .notFound
        case (400, _): return .badRequest(message)
        default: return .server(message)
        }
    }
}

private struct AnyEncodable: Encodable {
    let value: any Encodable
    init(_ value: any Encodable) { self.value = value }
    func encode(to encoder: any Encoder) throws { try value.encode(to: encoder) }
}
