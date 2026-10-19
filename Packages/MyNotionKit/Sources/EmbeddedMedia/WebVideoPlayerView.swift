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
        (view as? WKWebView)?.uiDelegate = navigationDelegate
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

    // MARK: Переходы

    enum NavigationDecision: Equatable {
        case allow
        /// Ссылка, по которой Юрий щёлкнул в проигрывателе: в браузере, проигрыватель остаётся.
        case openInBrowser
        case cancel
    }

    /// Страницы проигрывателей: YouTube (`/embed/…`) и Vimeo (`player.vimeo.com/video/…`).
    private static func isPlayerPage(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host()?.lowercased() else { return false }
        switch host {
        case "www.youtube-nocookie.com", "youtube-nocookie.com", "www.youtube.com", "youtube.com": return url.path.hasPrefix("/embed/")
        case "player.vimeo.com": return url.path.hasPrefix("/video/")
        default: return false
        }
    }

    /// Сайт YouTube или Vimeo — туда ведут ссылки самого проигрывателя.
    static func isVideoSite(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        return ["youtube.com", "youtu.be", "vimeo.com"].contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Главная рамка — только страница проигрывателя; рамки внутри неё — только веб-адреса. Щелчок по ссылке
    /// http или https («Смотреть на YouTube») — в браузер; прочее (другие сайты, smb, ssh…) — нет.
    static func navigationDecision(for url: URL, embedURL: URL, isMainFrame: Bool, userInitiated: Bool) -> NavigationDecision {
        let scheme = url.scheme?.lowercased()
        if url.absoluteString == "about:blank" || url.absoluteString == "about:srcdoc" { return .allow }
        if isMainFrame, url == embedURL || isPlayerPage(url) { return .allow }
        let isWeb = scheme == "http" || scheme == "https"
        if !isMainFrame, !userInitiated { return isWeb || scheme == "blob" || scheme == "data" ? .allow : .cancel }
        return userInitiated && isWeb ? .openInBrowser : .cancel
    }

    /// Загрузка не вышла из-за сети, а не потому что её отменили (переход запрещён, вид закрыт).
    static func isOffline(_ error: any Error) -> Bool {
        let error = error as NSError
        if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled { return false }
        // WebKitErrorFrameLoadInterruptedByPolicyChange.
        if error.domain == "WebKitErrorDomain", error.code == 102 { return false }
        return true
    }

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

    private final class NavigationDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
        weak var owner: WebVideoPlayerView?

        init(owner: WebVideoPlayerView) {
            self.owner = owner
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url, let owner else { return decisionHandler(.cancel) }
            let decision = WebVideoPlayerView.navigationDecision(
                for: url, embedURL: owner.embedURL, isMainFrame: navigationAction.targetFrame?.isMainFrame ?? true,
                userInitiated: navigationAction.navigationType == .linkActivated)
            if decision == .openInBrowser { NSWorkspace.shared.open(url) }
            decisionHandler(decision == .allow ? .allow : .cancel)
        }

        /// Новых окон проигрыватель не открывает: ссылка с `target=_blank` по щелчку — в браузере.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            // Окно, открытое щелчком или самим YouTube и Vimeo («Смотреть на YouTube» открывается скриптом).
            if let url = navigationAction.request.url, let owner,
               WebVideoPlayerView.navigationDecision(
                   for: url, embedURL: owner.embedURL, isMainFrame: false,
                   userInitiated: navigationAction.navigationType == .linkActivated || WebVideoPlayerView.isVideoSite(url)) == .openInBrowser {
                NSWorkspace.shared.open(url)
            }
            return nil
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            if WebVideoPlayerView.isOffline(error) { owner?.showOffline() }
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
