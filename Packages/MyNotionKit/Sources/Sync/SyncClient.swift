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
    /// Файл уже собран и не меняется (`409 file_complete`).
    case fileComplete
    /// Файл ещё не собран: другой Mac не закончил отправку (`409 file_incomplete`).
    case fileIncomplete
    /// Кончилось место для файлов, общих для ваших Mac — новые файлы пока ждут на этом Mac (`507 storage_full`).
    case storageFull
    /// Доступ по ссылке выключен — снимок не нужен (`409 share_disabled`).
    case shareDisabled

    public var errorDescription: String? {
        switch self {
        case .unauthorized: "Этот Mac убрали из списка ваших Mac — подключите его заново в настройках"
        case .inviteExpired: "Код устарел или им уже подключили другой Mac — нажмите «Добавить Mac» на другом Mac ещё раз"
        case .tooLarge: "Правка слишком большая, чтобы отправить её за раз"
        case .logCompacted: "Догоняю другие Mac — загружаю все записи целиком"
        case .notFound: "Не нашлось того, что нужно для связи с другими Mac — попробую ещё раз сам"
        case .badRequest, .server: "Другие Mac сейчас не отвечают — попробую ещё раз сам"
        case .fileComplete: "Этот файл уже передан целиком"
        case .fileIncomplete: "Ждёт отправки с другого Mac"
        case .storageFull: "Кончилось место для файлов, общих для ваших Mac — новые файлы пока ждут на этом Mac"
        case .shareDisabled: "Доступ по ссылке выключен"
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
    /// Устройство, которому принадлежит токен (`GET /devices/me`).
    func currentDevice() async throws -> SyncDevice
    func invite() async throws -> SyncInvite
    func deleteDevice(_ deviceId: String) async throws
}

/// Сервер: подключение нового устройства без токена и запросы с токеном.
public protocol SyncServer: Sendable {
    func join(inviteCode: String, deviceName: String) async throws -> SyncJoinResult
    func transport(deviceToken: String) -> any SyncTransport
}

/// Что лежит на сервере от файла (`GET /files/{id}`).
public struct SyncFileStatus: Sendable, Hashable, Codable {
    public let fileId: String
    public let partCount: Int
    public let parts: [Int]
    public let complete: Bool
    public let bytes: Int

    public init(fileId: String, partCount: Int, parts: [Int], complete: Bool, bytes: Int) {
        self.fileId = fileId
        self.partCount = partCount
        self.parts = parts
        self.complete = complete
        self.bytes = bytes
    }
}

/// Место файлов на сервере (`GET /files/usage`) — для «Настройки → Синхронизация».
public struct SyncFilesUsage: Sendable, Hashable, Codable {
    public let usedBytes: Int
    public let limitBytes: Int
    public let files: Int

    public init(usedBytes: Int, limitBytes: Int, files: Int) {
        self.usedBytes = usedBytes
        self.limitBytes = limitBytes
        self.files = files
    }
}

/// Файлы на сервере (contracts/sync-and-files-api.md, «Файлы на сервере»): зашифрованные части, сервер блоков не знает.
public protocol SyncFileTransport: Sendable {
    /// Что уже лежит; `nil` — ничего (ещё не начали отправку или стёрт).
    func fileStatus(_ fileId: UUID) async throws -> SyncFileStatus?
    /// Часть как есть; повтор той же части безопасен.
    func putFilePart(_ fileId: UUID, index: Int, count: Int, data: Data) async throws
    func completeFile(_ fileId: UUID, partCount: Int) async throws
    /// Часть собранного файла; до сборки — `fileIncomplete`, нет — `notFound`.
    func filePart(_ fileId: UUID, index: Int) async throws -> Data
    /// В корзину сервера; повтор безопасен.
    func deleteFile(_ fileId: UUID) async throws
    func filesUsage() async throws -> SyncFilesUsage
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

    public func fileTransport(deviceToken: String) -> any SyncFileTransport {
        HTTPSyncTransport(baseURL: url, token: deviceToken, session: Self.fileSession)
    }

    public func shareTransport(deviceToken: String) -> any SyncShareTransport {
        HTTPSyncTransport(baseURL: url, token: deviceToken, session: Self.fileSession)
    }

    /// Части по 8 МБ: тайм-аут на запрос — как у сервера на чтение тела (120 с).
    public static let fileSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 600
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: configuration)
    }()
}

struct HTTPSyncTransport: SyncTransport, SyncFileTransport {
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

    func currentDevice() async throws -> SyncDevice {
        try await send("GET", "devices/me")
    }

    func invite() async throws -> SyncInvite {
        try await send("POST", "devices/invite", body: [String: String]())
    }

    func deleteDevice(_ deviceId: String) async throws {
        let _: Ignored = try await send("DELETE", "devices/\(deviceId)")
    }

    // MARK: Файлы

    func fileStatus(_ fileId: UUID) async throws -> SyncFileStatus? {
        do {
            return try await send("GET", "files/\(fileId.uuidString.lowercased())")
        } catch SyncServerError.notFound {
            return nil
        }
    }

    func putFilePart(_ fileId: UUID, index: Int, count: Int, data: Data) async throws {
        let _: Ignored = try await send("PUT", "files/\(fileId.uuidString.lowercased())/parts/\(index)", query: ["count": "\(count)"],
                                        rawBody: data)
    }

    func completeFile(_ fileId: UUID, partCount: Int) async throws {
        let _: Ignored = try await send("POST", "files/\(fileId.uuidString.lowercased())/complete", body: ["partCount": partCount])
    }

    func filePart(_ fileId: UUID, index: Int) async throws -> Data {
        let request = try makeRequest("GET", "files/\(fileId.uuidString.lowercased())/parts/\(index)")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Self.error(status: status, data: data) }
        return data
    }

    func deleteFile(_ fileId: UUID) async throws {
        let _: Ignored = try await send("DELETE", "files/\(fileId.uuidString.lowercased())")
    }

    func filesUsage() async throws -> SyncFilesUsage {
        try await send("GET", "files/usage")
    }

    // MARK: Запрос

    struct Ignored: Decodable {
        init(from decoder: any Decoder) throws {}
        init() {}
    }

    private struct ErrorBody: Decodable {
        let error: String
        let message: String?
        let snapshotSeq: Int?
    }

    func send<Answer: Decodable>(_ method: String, _ path: String, query: [String: String] = [:],
                                 body: (any Encodable)? = nil, rawBody: Data? = nil) async throws -> Answer {
        var request = try makeRequest(method, path, query: query)
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(AnyEncodable(body))
        } else if let rawBody {
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.httpBody = rawBody
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Self.error(status: status, data: data) }
        if Answer.self == Ignored.self || data.isEmpty { return try SyncJSON.decoder().decode(Answer.self, from: Data("{}".utf8)) }
        return try SyncJSON.decoder().decode(Answer.self, from: data)
    }

    func makeRequest(_ method: String, _ path: String, query: [String: String] = [:]) throws -> URLRequest {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    static func error(status: Int, data: Data) -> SyncServerError {
        let body = try? JSONDecoder().decode(ErrorBody.self, from: data)
        let message = body?.message ?? "HTTP \(status)"
        switch (status, body?.error) {
        case (401, _), (_, "unauthorized"): return .unauthorized
        case (410, "log_compacted"): return .logCompacted(snapshotSeq: body?.snapshotSeq ?? 0)
        case (410, _), (_, "invite_expired"): return .inviteExpired
        case (413, _), (_, "too_large"): return .tooLarge
        case (_, "file_complete"): return .fileComplete
        case (_, "file_incomplete"): return .fileIncomplete
        case (507, _), (_, "storage_full"): return .storageFull
        case (_, "share_disabled"): return .shareDisabled
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
