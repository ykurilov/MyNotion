import Foundation

/// Ответ сайта: тело (не больше предела), адрес после переадресаций, тип содержимого.
public struct FetchedPage: Sendable {
    public var data: Data
    public var url: URL
    public var contentType: String?

    public init(data: Data, url: URL, contentType: String?) {
        self.data = data
        self.url = url
        self.contentType = contentType
    }
}

/// Сеть для карточек и обложек; в тестах — подменённая.
public protocol LinkFetching: Sendable {
    /// Страница: не больше 512 КБ, лишнее отбрасывается.
    func fetch(_ url: URL) async throws -> FetchedPage
    /// Файл (картинка сайта, обложка): больше предела — ошибка, обрезанная картинка не нужна.
    func fetchFile(_ url: URL, byteLimit: Int) async throws -> FetchedPage
}

/// Запрос ушёл бы на этот Mac или в локальную сеть (`NetworkAddressPolicy`).
public enum LinkFetchError: Error, Equatable {
    case localAddress
}

/// Один запрос `URLSession` (research R15): до 512 КБ страницы и не дольше 10 с. Тело читается кусками, как приходит;
/// этот Mac и локальная сеть закрыты — и в начальном адресе, и в переадресации.
public struct URLSessionLinkFetcher: LinkFetching {
    public static let pageByteLimit = 512 * 1024
    public static let timeout: TimeInterval = 10
    let configuration: @Sendable () -> URLSessionConfiguration
    let timeout: TimeInterval
    let addresses: NetworkAddressPolicy
    /// Адрес в локальной сети, который Юрий ввёл сам («Вставить ссылку» на файл с NAS), открыт; переадресация
    /// из интернета в локальную сеть — всё равно нет.
    let allowsLocalStart: Bool

    public init(configuration: @escaping @Sendable () -> URLSessionConfiguration = URLSessionLinkFetcher.configuration,
                timeout: TimeInterval = URLSessionLinkFetcher.timeout, addresses: NetworkAddressPolicy = .system,
                allowsLocalStart: Bool = false) {
        self.configuration = configuration
        self.timeout = timeout
        self.addresses = addresses
        self.allowsLocalStart = allowsLocalStart
    }

    public static let configuration: @Sendable () -> URLSessionConfiguration = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.httpCookieAcceptPolicy = .never
        return configuration
    }

    /// Многие сайты отдают пустую страницу без имени браузера.
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    public func fetch(_ url: URL) async throws -> FetchedPage {
        try await read(url, byteLimit: Self.pageByteLimit, truncates: true)
    }

    public func fetchFile(_ url: URL, byteLimit: Int) async throws -> FetchedPage {
        try await read(url, byteLimit: byteLimit, truncates: false)
    }

    private func read(_ url: URL, byteLimit: Int, truncates: Bool) async throws -> FetchedPage {
        guard ["http", "https"].contains(url.scheme?.lowercased()) else { throw URLError(.unsupportedURL) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("ru,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        let configuration = configuration
        let timeout = timeout
        let addresses = addresses
        let allowsLocalStart = allowsLocalStart
        let preparedRequest = request
        // Предел времени — на весь ответ, а не на тишину между кусками.
        return try await withThrowingTaskGroup(of: FetchedPage.self) { group in
            group.addTask {
                let startsLocal = !addresses.allows(url)
                if startsLocal, !allowsLocalStart { throw LinkFetchError.localAddress }
                let delegate = ChunkedResponse { startsLocal || addresses.allows($0) }
                let session = URLSession(configuration: configuration(), delegate: delegate, delegateQueue: nil)
                defer { session.invalidateAndCancel() }
                session.dataTask(with: preparedRequest).resume()
                var response: URLResponse?
                var data = Data()
                reading: for try await piece in delegate.pieces {
                    switch piece {
                    case .response(let received):
                        let status = (received as? HTTPURLResponse)?.statusCode ?? 200
                        guard (200..<300).contains(status) else { throw URLError(.badServerResponse) }
                        response = received
                        data.reserveCapacity(min(byteLimit, max(0, Int(received.expectedContentLength)), 16 << 20))
                    case .data(let chunk):
                        guard data.count + chunk.count <= byteLimit else {
                            guard truncates else { throw URLError(.dataLengthExceedsMaximum) }
                            data.append(chunk.prefix(byteLimit - data.count))
                            break reading
                        }
                        data.append(chunk)
                    }
                }
                return FetchedPage(data: data, url: response?.url ?? url, contentType: response?.mimeType)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}

/// Ответ запроса кусками, как их отдаёт сеть; переадресация — только туда, куда пускает `allowsRedirect`.
private final class ChunkedResponse: NSObject, URLSessionDataDelegate, Sendable {
    enum Piece {
        case response(URLResponse)
        case data(Data)
    }

    let pieces: AsyncThrowingStream<Piece, any Error>
    private let continuation: AsyncThrowingStream<Piece, any Error>.Continuation
    private let allowsRedirect: @Sendable (URL) -> Bool

    init(allowsRedirect: @escaping @Sendable (URL) -> Bool) {
        (pieces, continuation) = AsyncThrowingStream.makeStream()
        self.allowsRedirect = allowsRedirect
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        continuation.yield(.response(response))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        continuation.yield(.data(data))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let url = request.url, ["http", "https"].contains(url.scheme?.lowercased()), allowsRedirect(url) else {
            completionHandler(nil)
            continuation.finish(throwing: LinkFetchError.localAddress)
            task.cancel()
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        continuation.finish(throwing: error)
    }
}

/// Название и обложка ролика из oEmbed.
public struct VideoInfo: Sendable, Hashable {
    public var title: String?
    public var thumbnailURL: URL?

    public init(title: String?, thumbnailURL: URL?) {
        self.title = title
        self.thumbnailURL = thumbnailURL
    }
}

/// Данные для карточки закладки и блока видео: один запрос при вставке; без сети — только адрес.
public struct LinkPreviewLoader: Sendable {
    /// Картинка сайта и обложка ролика больше 10 МБ не сохраняются.
    public static let imageByteLimit = 10 * 1_048_576
    let fetcher: any LinkFetching

    public init(fetcher: any LinkFetching = URLSessionLinkFetcher()) {
        self.fetcher = fetcher
    }

    public func metadata(for url: URL) async -> LinkMetadata {
        guard let page = try? await fetcher.fetch(url) else { return LinkMetadata(url: url) }
        var metadata = HTMLMetadata.parse(page.data, url: page.url)
        metadata.url = url
        return metadata
    }

    public func videoInfo(for link: VideoLink) async -> VideoInfo? {
        struct OEmbed: Decodable {
            let title: String?
            let thumbnail_url: String?
        }
        guard let page = try? await fetcher.fetch(link.oEmbedURL),
              let answer = try? JSONDecoder().decode(OEmbed.self, from: page.data) else { return nil }
        return VideoInfo(title: answer.title, thumbnailURL: answer.thumbnail_url.flatMap(URL.init(string:)))
    }

    /// Картинка по адресу; не вышло — `nil`.
    public func image(at url: URL) async -> FetchedPage? {
        try? await fetcher.fetchFile(url, byteLimit: Self.imageByteLimit)
    }
}
