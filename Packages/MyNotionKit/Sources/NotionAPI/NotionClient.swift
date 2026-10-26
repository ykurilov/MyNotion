import Foundation

/// Картинка блока Notion по ключу интеграции: `GET /v1/blocks/{id}` даёт временную ссылку на файл (или внешний адрес),
/// файл скачивается по ней уже без ключа. Доступ — только к страницам, к которым подключена интеграция.
public struct NotionClient: Sendable {
    /// Отправка запроса; в тестах — подменный ответ.
    public typealias Send = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public static let version = "2026-03-11"
    static let api = URL(string: "https://api.notion.com/v1/")!
    /// Ответ API — быстрый; файл — до 100 МБ.
    static let apiTimeout: TimeInterval = 20
    static let fileTimeout: TimeInterval = 120

    private let key: @Sendable () async throws -> String?
    private let send: Send
    private let byteLimit: Int

    public init(key: @escaping @Sendable () async throws -> String?, send: Send? = nil, byteLimit: Int = 100 * 1_048_576) {
        self.key = key
        self.send = send ?? Self.urlSession
        self.byteLimit = byteLimit
    }

    /// «Проверить» в Настройках: ключ подходит, если Notion отдаёт по нему пользователя интеграции.
    public func checkKey(_ key: String) async throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw NotionAPIError.missingKey }
        _ = try await perform(apiRequest("users/me", key: key))
    }

    /// Файл картинки блока `id`.
    public func image(ofBlock id: UUID) async throws -> NotionImage {
        guard let key = try await key()?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw NotionAPIError.missingKey
        }
        let (data, _) = try await perform(apiRequest("blocks/" + id.uuidString.lowercased(), key: key))
        guard let fileURL = Self.imageURL(fromBlock: data) else { throw NotionAPIError.notImage }
        return try await downloadImage(fileURL)
    }

    /// Адрес файла из ответа о блоке: `image.file.url` (файл в Notion) или `image.external.url`.
    static func imageURL(fromBlock data: Data) -> URL? {
        guard let block = try? JSONSerialization.jsonObject(with: data) as? [String: Any], block["type"] as? String == "image",
              let image = block["image"] as? [String: Any] else { return nil }
        let source = (image["file"] ?? image["external"]) as? [String: Any]
        guard let url = (source?["url"] as? String).flatMap(URL.init(string:)),
              ["http", "https"].contains(url.scheme?.lowercased()) else { return nil }
        return url
    }

    /// Файл по временной ссылке — без ключа: ссылка ведёт на хранилище файлов, а не в Notion.
    private func downloadImage(_ url: URL) async throws -> NotionImage {
        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await perform(URLRequest(url: url, timeoutInterval: Self.fileTimeout))
        } catch NotionAPIError.badKey, NotionAPIError.noAccess, NotionAPIError.unavailable, NotionAPIError.rateLimited {
            throw NotionAPIError.downloadFailed
        }
        guard data.count <= byteLimit else { throw NotionAPIError.tooLarge }
        let mime = response.mimeType?.lowercased()
        // Страница входа или ошибка хранилища вместо картинки.
        if let mime, mime.hasPrefix("text/") || mime.contains("json") || mime.contains("xml") { throw NotionAPIError.notImage }
        let name = url.lastPathComponent
        return NotionImage(data: data, contentType: mime, fileName: name.isEmpty || name == "/" ? nil : name)
    }

    private func apiRequest(_ path: String, key: String) -> URLRequest {
        var request = URLRequest(url: URL(string: path, relativeTo: Self.api)!.absoluteURL, timeoutInterval: Self.apiTimeout)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.version, forHTTPHeaderField: "Notion-Version")
        return request
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await send(request)
        } catch let error as URLError {
            switch error.code {
            case .cancelled: throw CancellationError()
            case .timedOut: throw NotionAPIError.timedOut
            case .dataLengthExceedsMaximum: throw NotionAPIError.tooLarge
            default: throw NotionAPIError.offline
            }
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw NotionAPIError.unavailable }
        switch http.statusCode {
        case 200..<300: return (data, http)
        case 401: throw NotionAPIError.badKey
        case 403, 404: throw NotionAPIError.noAccess
        case 429: throw NotionAPIError.rateLimited
        default: throw NotionAPIError.unavailable
        }
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = apiTimeout
        configuration.timeoutIntervalForResource = fileTimeout
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    private static let urlSession: Send = { request in try await session.data(for: request) }
}

/// Скачанная картинка: тип MIME и имя файла из ссылки, если они есть.
public struct NotionImage: Sendable {
    public var data: Data
    public var contentType: String?
    public var fileName: String?

    public init(data: Data, contentType: String?, fileName: String?) {
        self.data = data
        self.contentType = contentType
        self.fileName = fileName
    }
}

/// Почему картинки нет — и что сделать. Видна на заглушке блока после имени файла и в Настройках.
public enum NotionAPIError: Error, LocalizedError, Equatable {
    case missingKey
    case badKey
    case noAccess
    case rateLimited
    case offline
    case timedOut
    case notImage
    case downloadFailed
    case tooLarge
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .missingKey: "Нет ключа Notion — добавьте его в Настройках и вставьте снова"
        case .badKey: "Ключ Notion не подошёл — проверьте его в Настройках"
        case .noAccess: "Нет доступа к странице — в Notion откройте «•••» → «Подключения», добавьте интеграцию и вставьте снова"
        case .rateLimited: "Notion просит подождать — вставьте снова через минуту"
        case .offline: "Нет связи с Notion — проверьте интернет и вставьте снова"
        case .timedOut: "Notion долго не отвечает — вставьте снова"
        case .notImage: "Notion не отдал картинку — вставьте снова"
        case .downloadFailed: "Картинка не скачалась — вставьте снова"
        case .tooLarge: "Картинка больше 100 МБ — MyNotion такие не хранит"
        case .unavailable: "Notion сейчас не отвечает — вставьте снова позже"
        }
    }
}

/// Ссылка на блок Notion внутри вставки: `notion-block:<id>`. Разбор буфера ставит её в блок-картинку,
/// службы вставки по ней скачивают файл через API. В страницу ссылка не попадает.
public enum NotionBlockLink {
    public static let scheme = "notion-block"

    public static func url(forBlock id: UUID) -> URL {
        URL(string: "\(scheme):\(id.uuidString.lowercased())")!
    }

    public static func blockId(from url: URL) -> UUID? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        return UUID(uuidString: String(url.absoluteString.dropFirst(scheme.count + 1)))
    }
}
