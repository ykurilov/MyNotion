import AppKit
import NotesCore
import SwiftUI
import VisualStyle

/// Где стоит окно корзины (contracts/visual-style.md, «Окно корзины»): справа от боковой панели,
/// низом у строки «Корзина», целиком внутри окна приложения.
enum TrashPanelLayout {
    /// Карточка в координатах окна (начало внизу слева). `contentHeight` — сколько хочет содержимое.
    static func cardFrame(windowSize: NSSize, sidebarMaxX: CGFloat, anchorRow: NSRect, contentHeight: CGFloat) -> NSRect {
        let margin = Metrics.TrashPanel.windowMargin
        let x = sidebarMaxX + Metrics.TrashPanel.sidebarGap
        let width = max(0, min(Metrics.TrashPanel.width, windowSize.width - margin - x))
        let height = max(0, min(contentHeight, Metrics.TrashPanel.maxHeight, windowSize.height - 2 * margin))
        let y = min(max(margin, anchorRow.minY), windowSize.height - margin - height)
        return NSRect(x: x, y: y, width: width, height: height)
    }
}

/// Окно корзины: всплывающая панель над страницей. Закрывается по Esc, щелчку мимо и повторному щелчку по «Корзине».
/// Удалить навсегда и очистить корзину — только после вопроса (`ConfirmationDialogWindow`).
@MainActor
final class TrashPanelController {
    /// Строка «Корзина»: от неё окно узнаёт своё место.
    weak var anchorView: NSView?
    private var panel: TrashPanelWindow?
    private var hosting: NSHostingView<TrashView>?
    private var entries: [Page] = []
    private var actions: TrashActions?
    /// Пока открыт вопрос, окно корзины не закрывается.
    private var isConfirming = false
    private var monitors: [Any] = []

    var isShown: Bool { panel?.isVisible == true }

    func toggle(entries: [Page], actions: TrashActions) {
        if isShown { close() } else { show(entries: entries, actions: actions) }
    }

    func update(entries: [Page], actions: TrashActions) {
        self.entries = entries
        self.actions = actions
        guard isShown else { return }
        hosting?.rootView = makeView()
        place()
    }

    func close() {
        guard let panel else { return }
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func show(entries: [Page], actions: TrashActions) {
        guard let parent = anchorView?.window else { return }
        self.entries = entries
        self.actions = actions
        let panel = self.panel ?? makePanel()
        hosting?.rootView = makeView()
        if panel.parent == nil { parent.addChildWindow(panel, ordered: .above) }
        place()
        panel.orderFront(nil)
        watchOutsideClicks()
    }

    private func makePanel() -> TrashPanelWindow {
        let hosting = NSHostingView(rootView: makeView())
        let panel = TrashPanelWindow(content: hosting)
        panel.onCancel = { [weak self] in self?.close() }
        self.panel = panel
        self.hosting = hosting
        return panel
    }

    private func makeView() -> TrashView {
        TrashView(
            entries: entries,
            actions: actions ?? TrashActions(restore: { _ in }, deleteForever: { _ in }, emptyTrash: {}),
            confirmDeleteForever: { [weak self] page in self?.confirmDeleteForever(page) },
            confirmEmptyTrash: { [weak self] in self?.confirmEmptyTrash() }
        )
    }

    private func place() {
        guard let panel, let anchorView, let parent = anchorView.window, let content = parent.contentView else { return }
        let anchor = anchorView.convert(anchorView.bounds, to: nil)
        let card = TrashPanelLayout.cardFrame(windowSize: content.bounds.size,
                                              sidebarMaxX: anchor.maxX + Metrics.Sidebar.panelInset,
                                              anchorRow: anchor,
                                              contentHeight: TrashView.preferredHeight(entryCount: entries.count))
        panel.setCard(parent.convertToScreen(card))
    }

    /// Щелчок мимо окна корзины закрывает его; щелчок по самой «Корзине» закроет её кнопка.
    private func watchOutsideClicks() {
        guard monitors.isEmpty else { return }
        let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let panel = self.panel, !self.isConfirming else { return event }
            let onAnchor = self.anchorView.map { $0.bounds.contains($0.convert(event.locationInWindow, from: nil)) && event.window === $0.window } ?? false
            if event.window !== panel, !onAnchor { self.close() }
            return event
        }
        monitors = monitor.map { [$0] } ?? []
    }

    // MARK: Вопросы

    private func confirmDeleteForever(_ page: Page) {
        confirm(title: "Удалить «\(page.displayTitle)» навсегда?",
                message: "Страница и её подстраницы сотрутся. Вернуть их будет нельзя.",
                action: "Удалить навсегда") { [weak self] in self?.actions?.deleteForever(page.id) }
    }

    private func confirmEmptyTrash() {
        confirm(title: "Очистить корзину?", message: "Все страницы из корзины сотрутся. Вернуть их будет нельзя.",
                action: "Очистить") { [weak self] in self?.actions?.emptyTrash() }
    }

    /// Вопрос — над содержимым окна и над окном корзины. После ответа ввод снова у окна корзины.
    private func confirm(title: String, message: String, action: String, perform: @escaping @MainActor () -> Void) {
        guard let parent = anchorView?.window else { return }
        isConfirming = true
        ConfirmationDialogWindow.present(over: parent, title: title, message: message, action: action) { [weak self] confirmed in
            self?.isConfirming = false
            self?.panel?.makeKey()
            if confirmed { perform() }
        }
    }
}

/// Окно без рамки под карточку корзины: тени, скругление и рамку рисует `TrashPanelSurfaceView`.
@MainActor
final class TrashPanelWindow: NSPanel {
    let surface: TrashPanelSurfaceView
    var onCancel: (() -> Void)?

    init(content: NSView) {
        surface = TrashPanelSurfaceView(cardSize: .zero)
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        contentView = surface
        surface.setContent(content)
        setAccessibilityIdentifier("trash-panel")
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) { onCancel?() }

    /// Поставить карточку в `card` (координаты экрана); окно больше на место под тени.
    func setCard(_ card: NSRect) {
        let margin = Metrics.TrashPanel.shadowMargin
        surface.cardSize = card.size
        setFrame(card.insetBy(dx: -margin, dy: -margin), display: true)
    }
}

/// Карточка окна корзины: рисуется как всплывающие меню (`PopupSurface`), содержимое обрезано по скруглению.
final class TrashPanelSurfaceView: NSView {
    var cardSize: NSSize { didSet { needsLayout = true; needsDisplay = true } }
    private var content: NSView?

    init(cardSize: NSSize) {
        self.cardSize = cardSize
        let margin = Metrics.TrashPanel.shadowMargin
        super.init(frame: NSRect(x: 0, y: 0, width: cardSize.width + 2 * margin, height: cardSize.height + 2 * margin))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    var cardRect: NSRect {
        let margin = Metrics.TrashPanel.shadowMargin
        return NSRect(x: margin, y: margin, width: cardSize.width, height: cardSize.height)
    }

    func setContent(_ view: NSView) {
        content?.removeFromSuperview()
        content = view
        view.wantsLayer = true
        view.layer?.cornerRadius = Metrics.PopupMenu.cornerRadius
        view.layer?.masksToBounds = true
        addSubview(view)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        content?.frame = cardRect
    }

    override func draw(_ dirtyRect: NSRect) {
        PopupSurface.draw(card: cardRect)
    }
}
