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
        let fetcher = URLSessionLinkFetcher(session: StubProtocol.session)
        let fetched = try await fetcher.fetch(page)
        #expect(fetched.data.count == 512 * 1024)
        #expect(HTMLMetadata.parse(fetched.data, url: page).title == "Большая")
        #expect(URLSessionLinkFetcher.pageByteLimit == 512 * 1024)
        #expect(URLSessionLinkFetcher.timeout == 10)
    }

    @Test func slowSiteGivesUpAfterTimeout() async {
        StubProtocol.hang()
        let fetcher = URLSessionLinkFetcher(session: StubProtocol.session, timeout: 0.3)
        let started = ContinuousClock.now
        let metadata = await LinkPreviewLoader(fetcher: fetcher).metadata(for: page)
        #expect(metadata == LinkMetadata(url: page))
        #expect(ContinuousClock.now - started < .seconds(3))
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
    private enum Mode { case data(Data), hang }
    private static let mode = Mutex<Mode>(.hang)

    static func respond(with data: Data) { mode.withLock { $0 = .data(data) } }
    static func hang() { mode.withLock { $0 = .hang } }

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard case .data(let data) = Self.mode.withLock({ $0 }) else { return }
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
