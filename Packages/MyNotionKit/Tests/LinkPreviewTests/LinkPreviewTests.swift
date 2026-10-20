import Foundation
import Synchronization
import Testing
@testable import LinkPreview

/// Закладки и обложки видео (research R15, R8): один запрос при вставке, разбор `<meta>`, oEmbed YouTube и Vimeo.
@Suite(.serialized) struct LinkPreviewTests {
    let page = URL(string: "https://example.com/blog/post?id=1")!

    // MARK: Разбор страницы

    @Test func openGraphTitleDescriptionAndImage() {
        let html = """
            <html><head>
            <title>Запасной заголовок</title>
            <meta property="og:title" content="Как мы делали MyNotion &amp; что вышло">
            <meta content='Заметки о &quot;быстром&quot; редакторе' property='og:description' />
            <meta property="og:image" content="/images/cover.png">
            <link rel="icon" href="/favicon-32.png" sizes="32x32">
            </head><body><meta property="og:title" content="Не отсюда"></body></html>
            """
        let metadata = HTMLMetadata.parse(Data(html.utf8), url: page)
        #expect(metadata.title == "Как мы делали MyNotion & что вышло")
        #expect(metadata.summary == "Заметки о \"быстром\" редакторе")
        #expect(metadata.imageURL == URL(string: "https://example.com/images/cover.png"))
        #expect(metadata.iconURL == URL(string: "https://example.com/favicon-32.png"))
        #expect(metadata.url == page)
    }

    @Test func plainTitleAndDescriptionWhenNoOpenGraph() {
        let html = """
            <HTML><HEAD><TITLE>
              Простая   страница
            </TITLE><meta name="description" content="Описание из name"><link rel="shortcut icon" href="icons/f.ico"></HEAD></HTML>
            """
        let metadata = HTMLMetadata.parse(Data(html.utf8), url: page)
        #expect(metadata.title == "Простая страница")
        #expect(metadata.summary == "Описание из name")
        #expect(metadata.imageURL == nil)
        #expect(metadata.iconURL == URL(string: "https://example.com/blog/icons/f.ico"))
    }

    @Test func iconFallsBackToFaviconAtSiteRoot() {
        let metadata = HTMLMetadata.parse(Data("<title>x</title>".utf8), url: page)
        #expect(metadata.iconURL == URL(string: "https://example.com/favicon.ico"))
    }

    @Test func pageInWindows1251IsDecoded() {
        let html = "<meta charset=\"windows-1251\"><title>Привет</title>"
        let data = html.data(using: .windowsCP1251)!
        #expect(HTMLMetadata.parse(data, url: page).title == "Привет")
    }

    // MARK: Видео

    @Test func youtubeAndVimeoLinksAreRecognized() {
        let cases: [(String, VideoLink?)] = [
            ("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s", .youtube(id: "dQw4w9WgXcQ")),
            ("https://youtu.be/dQw4w9WgXcQ?si=abc", .youtube(id: "dQw4w9WgXcQ")),
            ("https://m.youtube.com/watch?v=dQw4w9WgXcQ", .youtube(id: "dQw4w9WgXcQ")),
            ("https://www.youtube.com/shorts/dQw4w9WgXcQ", .youtube(id: "dQw4w9WgXcQ")),
            ("https://www.youtube.com/embed/dQw4w9WgXcQ", .youtube(id: "dQw4w9WgXcQ")),
            ("https://vimeo.com/76979871", .vimeo(id: "76979871")),
            ("https://player.vimeo.com/video/76979871", .vimeo(id: "76979871")),
            ("https://www.youtube.com/channel/UC123", nil),
            ("https://example.com/watch?v=dQw4w9WgXcQ", nil),
            ("https://vimeo.com/about", nil),
        ]
        for (text, expected) in cases {
            #expect(VideoLink(url: URL(string: text)!) == expected, "\(text)")
        }
        #expect(VideoLink.youtube(id: "dQw4w9WgXcQ").embedURL == URL(string: "https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ?autoplay=1"))
        #expect(VideoLink.vimeo(id: "76979871").embedURL == URL(string: "https://player.vimeo.com/video/76979871?autoplay=1"))
        #expect(VideoLink.youtube(id: "dQw4w9WgXcQ").oEmbedURL.absoluteString
            == "https://www.youtube.com/oembed?url=https://www.youtube.com/watch?v%3DdQw4w9WgXcQ&format=json")
        #expect(VideoLink.vimeo(id: "76979871").oEmbedURL.absoluteString
            == "https://vimeo.com/api/oembed.json?url=https://vimeo.com/76979871")
    }

    @Test func oEmbedGivesTitleAndCover() async {
        let fetcher = FakeFetcher(pages: [
            VideoLink.youtube(id: "abc").oEmbedURL: #"{"title":"Ролик про редактор","thumbnail_url":"https://i.ytimg.com/vi/abc/hqdefault.jpg","type":"video"}"#,
            VideoLink.vimeo(id: "1").oEmbedURL: #"{"title":"Vimeo ролик","thumbnail_url":"https://i.vimeocdn.com/video/1_640.jpg"}"#,
        ])
        let loader = LinkPreviewLoader(fetcher: fetcher)
        let youtube = await loader.videoInfo(for: .youtube(id: "abc"))
        #expect(youtube == VideoInfo(title: "Ролик про редактор", thumbnailURL: URL(string: "https://i.ytimg.com/vi/abc/hqdefault.jpg")))
        #expect(await loader.videoInfo(for: .vimeo(id: "1"))?.title == "Vimeo ролик")
    }

    @Test func withoutNetworkOnlyTheAddressRemains() async {
        let loader = LinkPreviewLoader(fetcher: FakeFetcher(pages: [:]))
        let metadata = await loader.metadata(for: page)
        #expect(metadata == LinkMetadata(url: page))
        #expect(await loader.videoInfo(for: .youtube(id: "x")) == nil)
    }

    @Test func loaderReadsPageAndFollowsRedirectBase() async {
        let final = URL(string: "https://www.example.com/post/")!
        let fetcher = FakeFetcher(pages: [page: "<meta property=og:image content=cover.jpg><title>T</title>"], redirects: [page: final])
        let metadata = await LinkPreviewLoader(fetcher: fetcher).metadata(for: page)
        #expect(metadata.url == page)
        #expect(metadata.title == "T")
        #expect(metadata.imageURL == URL(string: "https://www.example.com/post/cover.jpg"))
    }

    // MARK: Пределы запроса

    @Test func pageIsReadAtMost512Kilobytes() async throws {
        let big = "<title>Большая</title>" + String(repeating: "x", count: 1_048_576)
        StubProtocol.respond(with: Data(big.utf8))
        let fetcher = URLSessionLinkFetcher(configuration: StubProtocol.configuration)
        let fetched = try await fetcher.fetch(page)
        #expect(fetched.data.count == 512 * 1024)
        #expect(HTMLMetadata.parse(fetched.data, url: page).title == "Большая")
        #expect(URLSessionLinkFetcher.pageByteLimit == 512 * 1024)
        #expect(URLSessionLinkFetcher.timeout == 10)
    }

    @Test func slowSiteGivesUpAfterTimeout() async {
        StubProtocol.hang()
        let fetcher = URLSessionLinkFetcher(configuration: StubProtocol.configuration, timeout: 0.3)
        let started = ContinuousClock.now
        let metadata = await LinkPreviewLoader(fetcher: fetcher).metadata(for: page)
        #expect(metadata == LinkMetadata(url: page))
        #expect(ContinuousClock.now - started < .seconds(3))
    }
}

extension LinkPreviewTests {
    // MARK: Только интернет

    /// Имена «из DNS» для тестов: сеть не нужна.
    static let addresses = NetworkAddressPolicy { host in
        switch host {
        case "example.com": ["93.184.216.34"]
        case "router.home": ["192.168.1.1"]
        case "both.example": ["93.184.216.34", "10.0.0.7"]
        default: []
        }
    }

    @Test func thisMacAndLocalNetworkAreNotFetched() async throws {
        StubProtocol.respond(with: Data("<title>Роутер</title>".utf8))
        let fetcher = URLSessionLinkFetcher(configuration: StubProtocol.configuration, addresses: Self.addresses)
        for text in ["http://127.0.0.1/", "http://localhost:8080/", "http://[::1]/", "http://192.168.0.1/", "http://10.1.2.3/",
                     "http://172.16.5.4/", "http://169.254.169.254/latest/meta-data", "http://100.64.0.1/", "http://0.0.0.0/",
                     "http://[fd00::1]/", "http://[fe80::1]/", "http://[::ffff:192.168.1.1]/", "http://router.home/",
                     "http://both.example/", "http://printer.local/"] {
            await #expect(throws: LinkFetchError.localAddress, "\(text)") { _ = try await fetcher.fetch(URL(string: text)!) }
        }
        #expect(try await fetcher.fetch(page).data == Data("<title>Роутер</title>".utf8))
        // Картинка сайта (og:image) — тем же путём.
        #expect(await LinkPreviewLoader(fetcher: fetcher).image(at: URL(string: "http://192.168.1.1/cam.jpg")!) == nil)
    }

    @Test func redirectIntoLocalNetworkIsNotFollowed() async throws {
        StubProtocol.redirect(page, to: URL(string: "http://192.168.1.1/reboot")!, then: Data("<title>Роутер</title>".utf8))
        let fetcher = URLSessionLinkFetcher(configuration: StubProtocol.configuration, addresses: Self.addresses)
        await #expect(throws: LinkFetchError.localAddress) { _ = try await fetcher.fetch(page) }
        #expect(!StubProtocol.requested.contains(URL(string: "http://192.168.1.1/reboot")!))

        StubProtocol.redirect(page, to: URL(string: "https://example.com/new")!, then: Data("<title>Новая</title>".utf8))
        let fetched = try await fetcher.fetch(page)
        #expect(fetched.url == URL(string: "https://example.com/new"))
        #expect(fetched.data == Data("<title>Новая</title>".utf8))
    }

    @Test func typedLocalAddressIsAllowedWhenAsked() async throws {
        StubProtocol.respond(with: Data("файл".utf8))
        let fetcher = URLSessionLinkFetcher(configuration: StubProtocol.configuration, addresses: Self.addresses, allowsLocalStart: true)
        #expect(try await fetcher.fetchFile(URL(string: "http://192.168.1.1/a.pdf")!, byteLimit: 100).data == Data("файл".utf8))
    }

    @Test func fileIsReadWholeAndLimitIsKept() async throws {
        let bytes = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        StubProtocol.respond(with: bytes)
        let fetcher = URLSessionLinkFetcher(configuration: StubProtocol.configuration, addresses: Self.addresses)
        #expect(try await fetcher.fetchFile(page, byteLimit: bytes.count).data == bytes)
        await #expect(throws: URLError.self) { _ = try await fetcher.fetchFile(page, byteLimit: bytes.count - 1) }
    }
}

/// Сеть из словаря: адрес → ответ.
struct FakeFetcher: LinkFetching {
    var pages: [URL: String]
    var redirects: [URL: URL] = [:]

    func fetch(_ url: URL) async throws -> FetchedPage {
        guard let text = pages[url] else { throw URLError(.notConnectedToInternet) }
        return FetchedPage(data: Data(text.utf8), url: redirects[url] ?? url, contentType: "text/html")
    }

    func fetchFile(_ url: URL, byteLimit: Int) async throws -> FetchedPage {
        try await fetch(url)
    }
}

/// Подменённый ответ сервера для `URLSession`.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    private enum Mode { case data(Data), hang, redirect(from: URL, to: URL, then: Data) }
    private static let mode = Mutex<Mode>(.hang)
    private static let log = Mutex<[URL]>([])
    /// Адреса, которые дошли до «сервера».
    static var requested: [URL] { log.withLock { $0 } }

    static func respond(with data: Data) { set(.data(data)) }
    static func hang() { set(.hang) }
    static func redirect(_ from: URL, to: URL, then data: Data) { set(.redirect(from: from, to: to, then: data)) }

    private static func set(_ newMode: Mode) {
        mode.withLock { $0 = newMode }
        log.withLock { $0 = [] }
    }

    static let configuration: @Sendable () -> URLSessionConfiguration = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.log.withLock { $0.append(request.url!) }
        let data: Data
        switch Self.mode.withLock({ $0 }) {
        case .hang: return
        case .data(let body): data = body
        case .redirect(let from, let to, let body):
            guard request.url == from else {
                data = body
                break
            }
            let response = HTTPURLResponse(url: from, statusCode: 302, httpVersion: nil, headerFields: ["Location": to.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: to), redirectResponse: response)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        var offset = 0
        while offset < data.count {
            let end = min(offset + 65_536, data.count)
            client?.urlProtocol(self, didLoad: data[offset..<end])
            offset = end
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
