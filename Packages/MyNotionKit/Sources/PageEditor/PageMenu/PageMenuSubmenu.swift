import AppKit
import VisualStyle

/// Подменю меню «•••» с переключателями («Вид страницы ›», contracts/pages-ui.md): карточка слева от пункта
/// (меню стоит у правого края окна), как «Appearance & layout» у Notion 7.39 (снимок `notion-page-appearance.png`).
/// Переключатель срабатывает сразу и меню не закрывает.
@MainActor
final class PageMenuSubmenu {
    private var panel: PageMenuSubmenuPanel?
    private(set) var rows: [PageMenuToggleRowView] = []

    var isShown: Bool { panel != nil }

    func show(_ toggles: [PageMenuToggle], context: PageMenuContext, besides row: NSView?) {
        guard panel == nil, let row, let window = row.window else { return }
        let rows = toggles.map { toggle in
            let view = PageMenuToggleRowView(title: toggle.title, isOn: toggle.isOn(context))
            view.onToggle = { toggle.toggle(context) }
            if let identifier = toggle.identifier { view.setAccessibilityIdentifier(identifier) }
            return view
        }
        self.rows = rows
        let size = NSSize(width: Metrics.PageMenu.submenuWidth,
                          height: CGFloat(rows.count) * Metrics.PopupMenu.compactRowHeight + 2 * Metrics.PopupMenu.verticalPadding)
        let content = PageMenuSubmenuView(rows: rows)
        let anchor = window.convertToScreen(row.convert(row.bounds, to: nil))
        var card = NSRect(x: anchor.minX - Metrics.PageMenu.submenuGap - size.width, y: anchor.maxY + Metrics.PopupMenu.verticalPadding - size.height,
                          width: size.width, height: size.height)
        if let screen = window.screen?.visibleFrame, card.minX < screen.minX { card.origin.x = anchor.maxX + Metrics.PageMenu.submenuGap }
        let panel = PageMenuSubmenuPanel(content: content)
        panel.setFrame(card.insetBy(dx: -PageMenuSubmenuView.shadowMargin, dy: -PageMenuSubmenuView.shadowMargin), display: false)
        self.panel = panel
        PopupWindows.show(panel, over: window)
    }

    func close() {
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        self.panel = nil
        rows = []
    }
}

@MainActor
private final class PageMenuSubmenuPanel: NSPanel {
    init(content: NSView) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        isReleasedWhenClosed = false
        contentView = content
    }
}

/// Карточка подменю: тень и рамка — как у меню.
@MainActor
final class PageMenuSubmenuView: NSView {
    static let shadowMargin: CGFloat = 32
    private let rows: [PageMenuToggleRowView]

    init(rows: [PageMenuToggleRowView]) {
        self.rows = rows
        super.init(frame: .zero)
        rows.forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    private var card: NSRect { bounds.insetBy(dx: Self.shadowMargin, dy: Self.shadowMargin) }

    override func layout() {
        super.layout()
        var y = card.minY + Metrics.PopupMenu.verticalPadding
        for row in rows {
            row.frame = NSRect(x: card.minX + Metrics.PopupMenu.rowInset, y: y, width: card.width - 2 * Metrics.PopupMenu.rowInset,
                               height: Metrics.PopupMenu.compactRowHeight)
            y += Metrics.PopupMenu.compactRowHeight
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        PopupSurface.draw(card: card)
    }
}

/// Строка подменю: название и переключатель справа (синий — включено, как у Notion).
@MainActor
final class PageMenuToggleRowView: NSView {
    let title: String
    private(set) var isOn: Bool
    var onToggle: (() -> Void)?
    private let titleLabel: NSTextField
    private var isHovered = false { didSet { needsDisplay = true } }

    init(title: String, isOn: Bool) {
        self.title = title
        self.isOn = isOn
        titleLabel = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        titleLabel.font = Typography.popupMenuTitle.font
        titleLabel.textColor = Palette.textPrimary
        addSubview(titleLabel)
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(title)
        setAccessibilityValue(isOn ? 1 : 0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    private var switchRect: NSRect {
        let size = Metrics.PageMenu.switchSize
        return NSRect(x: bounds.maxX - Metrics.PopupMenu.rowHorizontalPadding - size.width, y: ((bounds.height - size.height) / 2).rounded(),
                      width: size.width, height: size.height)
    }

    override func layout() {
        super.layout()
        let size = titleLabel.intrinsicContentSize
        titleLabel.frame = NSRect(x: Metrics.PopupMenu.rowHorizontalPadding, y: (bounds.height - size.height) / 2,
                                  width: switchRect.minX - 2 * Metrics.PopupMenu.rowHorizontalPadding, height: size.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered {
            Palette.hoverBackground.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: Metrics.PopupMenu.rowHighlightInset, dy: 0), xRadius: Metrics.PopupMenu.rowCornerRadius,
                         yRadius: Metrics.PopupMenu.rowCornerRadius).fill()
        }
        let track = switchRect
        (isOn ? Palette.focusRing : Palette.switchOff).setFill()
        NSBezierPath(roundedRect: track, xRadius: track.height / 2, yRadius: track.height / 2).fill()
        let knob = track.height - 4
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: isOn ? track.maxX - 2 - knob : track.minX + 2, y: track.minY + 2, width: knob, height: knob)).fill()
    }

    func press() {
        isOn.toggle()
        setAccessibilityValue(isOn ? 1 : 0)
        needsDisplay = true
        onToggle?()
    }

    override func accessibilityPerformPress() -> Bool {
        press()
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { press() }
    }
}
