import AppKit
import Testing
@testable import EmbeddedMedia

/// Проигрыватели видео (research R8): создаются только по нажатию, в окне — не больше одного, уход с экрана закрывает.
@MainActor
@Suite("Проигрыватели видео", .serialized)
struct EmbeddedPlayersTests {
    private func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = NSView(frame: window.contentLayoutRect)
        return window
    }

    private func webPlayer(_ created: Counter) -> WebVideoPlayerView {
        WebVideoPlayerView(embedURL: URL(string: "https://www.youtube-nocookie.com/embed/x?autoplay=1")!) { _ in
            created.value += 1
            return NSView()
        }
    }

    final class Counter { var value = 0 }

    @Test("Веб-проигрыватель создаётся только по «Играть»")
    func webViewOnlyOnPlay() {
        let created = Counter()
        let window = window()
        let player = webPlayer(created)
        window.contentView?.addSubview(player)
        #expect(player.webView == nil)
        #expect(created.value == 0)
        player.play()
        #expect(player.webView != nil)
        #expect(created.value == 1)
        player.play()
        #expect(created.value == 1)
        player.removeFromSuperview()
    }

    @Test("Запуск второго видео в окне закрывает первое; в другом окне — нет")
    func onePlayerPerWindow() {
        let created = Counter()
        let first = window()
        let second = window()
        let a = webPlayer(created)
        let b = webPlayer(created)
        let c = webPlayer(created)
        first.contentView?.addSubview(a)
        first.contentView?.addSubview(b)
        second.contentView?.addSubview(c)
        a.play()
        c.play()
        b.play()
        #expect(!a.isPlaying)
        #expect(b.isPlaying)
        #expect(c.isPlaying)
        let file = VideoFilePlayerView(fileURL: URL(fileURLWithPath: "/tmp/нет-файла.mov"))
        first.contentView?.addSubview(file)
        file.play()
        #expect(!b.isPlaying, "видеофайл тоже закрывает веб-проигрыватель окна")
        #expect(file.isPlaying)
        for view in [a, b, c, file] as [NSView] { view.removeFromSuperview() }
        #expect(EmbeddedPlayers.openCount == 0)
    }

    @Test("Вид ушёл с экрана (из окна) — проигрыватель закрыт и отпущен")
    func closesWhenRemoved() {
        let created = Counter()
        let window = window()
        let player = webPlayer(created)
        window.contentView?.addSubview(player)
        player.play()
        player.removeFromSuperview()
        #expect(player.webView == nil)
        let file = VideoFilePlayerView(fileURL: URL(fileURLWithPath: "/tmp/нет-файла.mov"))
        window.contentView?.addSubview(file)
        #expect(file.playerView == nil)
        file.play()
        #expect(file.playerView != nil)
        file.removeFromSuperview()
        #expect(file.playerView == nil)
        #expect(EmbeddedPlayers.openCount == 0)
    }

    @Test("Уход со страницы закрывает проигрыватель окна")
    func closeAllInWindow() {
        let created = Counter()
        let window = window()
        let player = webPlayer(created)
        window.contentView?.addSubview(player)
        player.play()
        EmbeddedPlayers.closeAll(in: window)
        #expect(!player.isPlaying)
        player.removeFromSuperview()
    }

    @Test("Проигрыватель уходит только на страницы проигрывателя YouTube и Vimeo; ссылки из него — в браузер, прочее — нет")
    func navigationStaysInsidePlayer() {
        let youtube = URL(string: "https://www.youtube-nocookie.com/embed/abc?autoplay=1")!
        let vimeo = URL(string: "https://player.vimeo.com/video/42?autoplay=1")!
        func decision(_ text: String, embed: URL = youtube, mainFrame: Bool = true, clicked: Bool = false) -> WebVideoPlayerView.NavigationDecision {
            WebVideoPlayerView.navigationDecision(for: URL(string: text)!, embedURL: embed, isMainFrame: mainFrame, userInitiated: clicked)
        }
        #expect(decision("https://www.youtube-nocookie.com/embed/abc?autoplay=1") == .allow)
        #expect(decision("https://www.youtube.com/embed/abc") == .allow)
        #expect(decision("https://player.vimeo.com/video/42", embed: vimeo) == .allow)
        #expect(decision("about:blank") == .allow)
        // Рамки внутри проигрывателя (реклама, счётчики) — только веб-адреса.
        #expect(decision("https://googleads.g.doubleclick.net/pagead/id", mainFrame: false) == .allow)
        #expect(decision("smb://nas/share", mainFrame: false) == .cancel)
        // Щелчок по названию ролика — в браузере; сама страница проигрывателя не меняется.
        #expect(decision("https://www.youtube.com/watch?v=abc", clicked: true) == .openInBrowser)
        #expect(decision("https://evil.example/phish") == .cancel)
        #expect(decision("vnc://host", clicked: true) == .cancel)
        #expect(decision("https://vimeo.com/42", embed: vimeo, clicked: true) == .openInBrowser)
    }

    @Test("Отменённая загрузка (-999, переход запрещён) — не «Нет подключения»; обрыв сети — да")
    func cancelledLoadIsNotOffline() {
        #expect(!WebVideoPlayerView.isOffline(URLError(.cancelled)))
        #expect(!WebVideoPlayerView.isOffline(NSError(domain: "WebKitErrorDomain", code: 102)))
        #expect(WebVideoPlayerView.isOffline(URLError(.notConnectedToInternet)))
        #expect(WebVideoPlayerView.isOffline(URLError(.timedOut)))
    }
}
