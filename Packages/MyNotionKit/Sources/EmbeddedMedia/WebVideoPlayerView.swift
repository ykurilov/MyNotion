import AppKit
import VisualStyle
import WebKit

/// Проигрыватель YouTube и Vimeo (research R8): страница встраивания в `WKWebView`. Создаётся только по нажатию
/// «Играть», в окне живёт не больше одного — запуск второго закрывает первый; закрывается, когда вид уходит
/// с экрана или из окна. В покое памяти не занимает.
@MainActor
public final class WebVideoPlayerView: NSView {
    public let embedURL: URL
    /// Создаёт веб-вид; в тестах — подменённый, без процессов WebKit.
    let makeWebView: @MainActor (URL) -> NSView
    public private(set) var webView: NSView?
    private let messageLabel = NSTextField(labelWithString: "")

    public convenience init(embedURL: URL) {
        self.init(embedURL: embedURL, makeWebView: WebVideoPlayerView.makeWebKitView)
    }

    init(embedURL: URL, makeWebView: @escaping @MainActor (URL) -> NSView) {
        self.embedURL = embedURL
        self.makeWebView = makeWebView
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerRadius = 4
        layer?.masksToBounds = true
        messageLabel.textColor = .white
        messageLabel.alignment = .center
        messageLabel.font = .systemFont(ofSize: 14)
        addSubview(messageLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    public var isPlaying: Bool { webView != nil }

    /// Создать веб-вид и начать показ. Другой проигрыватель этого окна закрывается.
    public func play() {
        guard webView == nil else { return }
        if let window { EmbeddedPlayers.willStart(self, in: window) }
        let view = makeWebView(embedURL)
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view, positioned: .below, relativeTo: messageLabel)
        webView = view
        (view as? WKWebView)?.navigationDelegate = navigationDelegate
    }

    /// Остановить и отпустить веб-вид со всеми его процессами.
    public func close() {
        guard let view = webView else { return }
        (view as? WKWebView)?.stopLoading()
        (view as? WKWebView)?.loadHTMLString("", baseURL: nil)
        view.removeFromSuperview()
        webView = nil
        EmbeddedPlayers.didClose(self)
    }

    /// Нет сети: «Нет подключения к интернету» поверх чёрного.
    func showOffline() {
        messageLabel.stringValue = "Нет подключения к интернету"
        webView?.isHidden = true
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            close()
        } else if webView != nil {
            EmbeddedPlayers.willStart(self, in: window!)
        }
    }

    public override func layout() {
        super.layout()
        messageLabel.frame = NSRect(x: 0, y: bounds.midY - 10, width: bounds.width, height: 20)
    }

    private lazy var navigationDelegate = NavigationDelegate(owner: self)

    static func makeWebKitView(_ url: URL) -> NSView {
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        view.load(URLRequest(url: url))
        view.setAccessibilityIdentifier("web-video-player")
        return view
    }

    private final class NavigationDelegate: NSObject, WKNavigationDelegate {
        weak var owner: WebVideoPlayerView?

        init(owner: WebVideoPlayerView) {
            self.owner = owner
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            owner?.showOffline()
        }
    }
}

/// Проигрыватели окон: в окне играет не больше одного видео (research R8).
@MainActor
public enum EmbeddedPlayers {
    private static var current: [ObjectIdentifier: WeakPlayer] = [:]

    private struct WeakPlayer {
        weak var player: NSView?
    }

    static func willStart(_ player: NSView, in window: NSWindow) {
        let key = ObjectIdentifier(window)
        if let previous = current[key]?.player, previous !== player { closePlayer(previous) }
        current[key] = WeakPlayer(player: player)
    }

    static func didClose(_ player: NSView) {
        current = current.filter { $0.value.player != nil && $0.value.player !== player }
    }

    /// Закрыть проигрыватель окна (уход со страницы).
    public static func closeAll(in window: NSWindow) {
        if let player = current[ObjectIdentifier(window)]?.player { closePlayer(player) }
    }

    /// Сколько проигрывателей сейчас открыто во всех окнах.
    public static var openCount: Int { current.values.filter { $0.player != nil }.count }

    private static func closePlayer(_ player: NSView) {
        (player as? WebVideoPlayerView)?.close()
        (player as? VideoFilePlayerView)?.close()
    }
}
