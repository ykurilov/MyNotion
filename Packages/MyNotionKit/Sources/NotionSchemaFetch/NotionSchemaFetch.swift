import Foundation

/// Почему схему базы прочитать не удалось — и что делать. Показывается в карточке импорта и в отчёте.
public struct NotionSchemaFailure: Sendable, Equatable {
    public enum Reason: Error, Sendable, Equatable {
        case noKey
        case invalidKey
        case noAccess
        case offline
        case rateLimited
        case server(Int)
        case unreadable

        public var explanation: String {
            switch self {
            case .noKey: "Нет ключа Notion — добавьте его в Настройках."
            case .invalidKey: "Ключ Notion не подошёл — проверьте его в Настройках."
            case .noAccess: "Нет доступа к базе — в Notion откройте «•••» → «Подключения» на странице базы и добавьте интеграцию."
            case .offline: "Нет связи с Notion — проверьте интернет."
            case .rateLimited: "Notion просит подождать — повторите через минуту."
            case .server(let code): "Notion не ответил как нужно (код \(code)) — повторите позже."
            case .unreadable: "Ответ Notion не удалось прочитать."
            }
        }
    }

    public var databaseId: String
    public var reason: Reason

    public init(databaseId: String, reason: Reason) {
        self.databaseId = databaseId
        self.reason = reason
    }
}

/// Что удалось прочитать: схемы по id базы (32 hex) и причины, почему какие-то базы не прочитаны.
public struct NotionSchemaFetchResult: Sendable, Equatable {
    public var schemas: [String: NotionDatabaseSchema] = [:]
    public var failures: [NotionSchemaFailure] = []

    public init(schemas: [String: NotionDatabaseSchema] = [:], failures: [NotionSchemaFailure] = []) {
        self.schemas = schemas
        self.failures = failures
    }

    /// База, которой принадлежит источник данных: связи Notion в новых версиях API указывают на источник.
    public func databaseId(ofDataSource id: String) -> String? {
        let wanted = NotionSchemaMapping.normalizedId(id)
        return schemas.first { $0.value.dataSourceId == wanted }?.key
    }
}

/// Схема баз из Notion по ключу интеграции (Q3, research R19): только `GET /v1/databases/{id}` и
/// `GET /v1/data_sources/{id}`. Ключ уходит в заголовок запроса и больше никуда: ни в ошибки, ни в результат.
public struct NotionSchemaFetch: Sendable {
    public typealias Send = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let api = "https://api.notion.com/v1/"
    static let version = "2026-03-11"
    static let requestTimeout: TimeInterval = 20
    /// Сколько раз повторять запрос, когда Notion просит подождать (429).
    static let retries = 3
    static let longestPause: Double = 30

    private let key: @Sendable () async throws -> String?
    private let send: Send
    private let pause: @Sendable (Double) async -> Void

    public init(key: @escaping @Sendable () async throws -> String?,
                send: Send? = nil,
                pause: (@Sendable (Double) async -> Void)? = nil) {
        self.key = key
        self.send = send ?? Self.urlSession
        self.pause = pause ?? { seconds in try? await Task.sleep(for: .seconds(seconds)) }
    }

    /// Схемы баз по их id (с дефисами или без): каждая база — свой запрос, отказ одной не мешает остальным.
    /// Нет ключа, неверный ключ и нет сети останавливают чтение: у остальных баз будет та же причина.
    public func fetch(databaseIds: [String]) async -> NotionSchemaFetchResult {
        var seen = Set<String>()
        let ids = databaseIds.map(NotionSchemaMapping.normalizedId).filter { seen.insert($0).inserted }
        var result = NotionSchemaFetchResult()
        guard let key = (try? await key())?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            result.failures = ids.map { NotionSchemaFailure(databaseId: $0, reason: .noKey) }
            return result
        }
        for (position, id) in ids.enumerated() {
            if Task.isCancelled { break }
            switch await schema(ofDatabase: id, key: key) {
            case .success(let schema):
                result.schemas[id] = schema
            case .failure(let reason):
                result.failures.append(NotionSchemaFailure(databaseId: id, reason: reason))
                if reason == .invalidKey || reason == .offline {
                    result.failures += ids[(position + 1)...].map { NotionSchemaFailure(databaseId: $0, reason: reason) }
                    return result
                }
            }
        }
        return result
    }

    private func schema(ofDatabase id: String, key: String) async -> Result<NotionDatabaseSchema, NotionSchemaFailure.Reason> {
        let reference: NotionDatabaseReference
        switch await get("databases/" + id, key: key) {
        case .failure(let reason): return .failure(reason)
        case .success(let data):
            guard let parsed = try? NotionSchemaMapping.databaseReference(from: data) else { return .failure(.unreadable) }
            reference = parsed
        }
        if let inline = reference.inlineSchema { return .success(inline) }
        guard let source = reference.dataSources.first else { return .failure(.unreadable) }
        switch await get("data_sources/" + source.id, key: key) {
        case .failure(let reason): return .failure(reason)
        case .success(let data):
            guard var schema = try? NotionSchemaMapping.schema(fromDataSource: data) else { return .failure(.unreadable) }
            if schema.databaseId.isEmpty { schema.databaseId = reference.id }
            return .success(schema)
        }
    }

    private func get(_ path: String, key: String) async -> Result<Data, NotionSchemaFailure.Reason> {
        var request = URLRequest(url: URL(string: Self.api + path)!, timeoutInterval: Self.requestTimeout)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.version, forHTTPHeaderField: "Notion-Version")
        for attempt in 0...Self.retries {
            let data: Data, response: URLResponse
            do {
                (data, response) = try await send(request)
            } catch {
                return .failure(.offline)
            }
            guard let http = response as? HTTPURLResponse else { return .failure(.unreadable) }
            switch http.statusCode {
            case 200..<300: return .success(data)
            case 401: return .failure(.invalidKey)
            case 403, 404: return .failure(.noAccess)
            case 429:
                guard attempt < Self.retries else { return .failure(.rateLimited) }
                let asked = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 1
                await pause(min(max(asked, 0), Self.longestPause))
            default: return .failure(.server(http.statusCode))
            }
        }
        return .failure(.rateLimited)
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    private static let urlSession: Send = { request in try await session.data(for: request) }
}
