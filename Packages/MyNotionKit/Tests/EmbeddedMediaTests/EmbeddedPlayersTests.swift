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
}
