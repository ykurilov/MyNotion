import AppKit

/// Всплывающая карточка у элемента окна — тот же вид, что меню и окно корзины (`PopupSurface`): подробности
/// синхронизации, сравнение «Двух версий». Целиком внутри окна приложения; закрывается по Esc,
/// щелчку мимо и уходу приложения в фон.
@MainActor
public final class PopupCard {
    private var panel: PopupCardPanel?
    private var monitor: Any?
    /// Подписка снимается в `deinit` — он не привязан к главному потоку.
    nonisolated(unsafe) private var deactivationObserver: NSObjectProtocol?

    deinit {
        if let deactivationObserver { NotificationCenter.default.removeObserver(deactivationObserver) }
    }

    /// Карточка закрылась (в том числе щелчком мимо).
    public var onClose: (() -> Void)?

    public init() {}

    public var isShown: Bool { panel?.isVisible == true }

    /// Показать `content` размером `size` рядом с `anchor` (вид окна), место — `cardFrame`.
    public func show(_ content: NSView, size: NSSize, besides anchor: NSView, gap: CGFloat = 8, preferringRight: Bool = true) {
        close()
        guard let window = anchor.window, let windowContent = window.contentView else { return }
        let card = Self.cardFrame(size: size, anchor: anchor.convert(anchor.bounds, to: nil), in: windowContent.bounds,
                                  gap: gap, preferringRight: preferringRight)

        let panel = PopupCardPanel(content: content)
        panel.onCancel = { [weak self] in self?.close() }
        panel.setCard(window.convertToScreen(card))
        self.panel = panel
        guard PopupWindows.show(panel, over: window, makingKey: true) else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let panel = self?.panel, event.window !== panel { self?.close() }
            return event
        }
        deactivationObserver = PopupWindows.onAppDeactivation { [weak self] in self?.close() }
    }

    /// Где встанет карточка размером `size` у `anchor` (координаты окна) внутри `bounds`: справа от него с зазором `gap`,
    /// низом по низу якоря; не влезает или `preferringRight == false` — под ним с тем же зазором, правым краем по якорю.
    /// Всегда целиком в окне с полем 8.
    nonisolated public static func cardFrame(size: NSSize, anchor: NSRect, in bounds: NSRect, gap: CGFloat,
                                             preferringRight: Bool) -> NSRect {
        let margin: CGFloat = 8
        var card = NSRect(origin: .zero, size: size)
        if preferringRight, anchor.maxX + gap + size.width <= bounds.maxX - margin {
            card.origin = NSPoint(x: anchor.maxX + gap, y: anchor.minY)
        } else {
            card.origin = NSPoint(x: anchor.maxX - size.width, y: anchor.minY - gap - size.height)
        }
        card.origin.x = min(max(margin, card.origin.x), bounds.maxX - margin - size.width)
        card.origin.y = min(max(margin, card.origin.y), bounds.maxY - margin - size.height)
        return card
    }

    public func close() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let deactivationObserver { NotificationCenter.default.removeObserver(deactivationObserver) }
        deactivationObserver = nil
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        self.panel = nil
        onClose?()
    }
}

/// Окно без рамки под карточку: тени, скругление и рамку рисует `PopupSurface`.
private final class PopupCardPanel: NSPanel {
    static let shadowMargin: CGFloat = 32
    private let surface = SurfaceView()
    var onCancel: (() -> Void)?

    init(content: NSView) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        contentView = surface
        surface.setContent(content)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }

    func setCard(_ card: NSRect) {
        surface.cardSize = card.size
        setFrame(card.insetBy(dx: -Self.shadowMargin, dy: -Self.shadowMargin), display: true)
    }

    private final class SurfaceView: NSView {
        var cardSize: NSSize = .zero { didSet { needsLayout = true; needsDisplay = true } }
        private var content: NSView?

        override var isFlipped: Bool { true }

        var cardRect: NSRect {
            NSRect(x: PopupCardPanel.shadowMargin, y: PopupCardPanel.shadowMargin, width: cardSize.width, height: cardSize.height)
        }

        func setContent(_ view: NSView) {
            content = view
            view.wantsLayer = true
            view.layer?.cornerRadius = Metrics.PopupMenu.cornerRadius
            view.layer?.masksToBounds = true
            addSubview(view)
        }

        override func layout() {
            super.layout()
            content?.frame = cardRect
        }

        override func draw(_ dirtyRect: NSRect) {
            PopupSurface.draw(card: cardRect, shadow: Palette.popupCardShadow)
        }
    }
}
