import AppKit
import VisualStyle

/// Строка «↗ 3 обратные ссылки» под названием страницы (contracts/pages-ui.md, «Обратные ссылки»): серая, высотой ≈24,
/// под мышью — подложка; щелчок открывает список (`onPress` получает саму строку как якорь окна).
/// Текст ставит хозяин: редактор не знает про индекс ссылок.
@MainActor
public final class BacklinksRow: NSView {
    public static let height = Metrics.BacklinksRow.height
    public private(set) var title: String
    public var onPress: ((NSView) -> Void)?
    private var isPointerInside = false { didSet { needsDisplay = true } }

    public init(title: String) {
        self.title = title
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        setAccessibilityIdentifier("backlinks-row")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    public override var isFlipped: Bool { true }

    public func show(title: String) {
        guard title != self.title else { return }
        self.title = title
        setAccessibilityLabel(title)
        needsDisplay = true
        invalidateIntrinsicContentSize()
    }

    private var attributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: Metrics.BacklinksRow.fontSize), .foregroundColor: Palette.textSecondary]
    }

    private var text: NSAttributedString { NSAttributedString(string: "↗ " + title, attributes: attributes) }

    /// Ширина подложки по тексту: строка не тянется на всю ширину страницы.
    public var fittingWidth: CGFloat { ceil(text.size().width) + 2 * Metrics.BacklinksRow.horizontalPadding }

    /// Откуда открывается список: левый верхний угол карточки — под строкой на 4, левым краем по подложке строки
    /// (T101 № 6: список не сдвигается к середине страницы). В координатах строки.
    public var listAnchor: NSPoint { NSPoint(x: 0, y: bounds.maxY + Metrics.BacklinksRow.listGap) }

    public override func accessibilityPerformPress() -> Bool {
        onPress?(self)
        return true
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    public override func mouseEntered(with event: NSEvent) { isPointerInside = true }
    public override func mouseExited(with event: NSEvent) { isPointerInside = false }
    public override func mouseDown(with event: NSEvent) {}
    public override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if point.x <= fittingWidth, bounds.contains(point) { onPress?(self) }
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        // Щелчок правее текста уходит в страницу: подложка занимает только ширину текста.
        let local = convert(point, from: superview)
        return local.x <= fittingWidth && bounds.contains(local) ? self : nil
    }

    public override func draw(_ dirtyRect: NSRect) {
        let plate = NSRect(x: 0, y: 0, width: min(fittingWidth, bounds.width), height: bounds.height)
        if isPointerInside {
            Palette.hoverBackground.setFill()
            NSBezierPath(roundedRect: plate, xRadius: Metrics.BacklinksRow.cornerRadius, yRadius: Metrics.BacklinksRow.cornerRadius).fill()
        }
        let drawn = text
        let size = drawn.size()
        drawn.draw(at: NSPoint(x: Metrics.BacklinksRow.horizontalPadding, y: ((bounds.height - size.height) / 2).rounded()))
    }
}
