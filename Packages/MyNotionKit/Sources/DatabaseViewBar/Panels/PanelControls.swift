import AppKit
import DatabaseGrid
import NotesCore
import VisualStyle

/// Мерки окон вида (Notion 7.39, снимки 20.10.2026; «≈» уточняет сверка по живому Notion).
@MainActor
enum PanelMetrics {
    /// Окно простого фильтра, сортировки, видимости, группировки, раскладки ≈ 290.
    static let windowWidth: CGFloat = 300
    /// Расширенный фильтр ≈ 620 (`notion-advanced-filter-nested-group.png`).
    static let advancedWidth: CGFloat = 640
    /// Сортировка: ручка, свойство, направление, ✕ ≈ 380.
    static let sortWidth: CGFloat = 400
    /// Выше — прокрутка.
    static let maxHeight: CGFloat = 560
    /// Строка с кнопками «свойство ▾ условие ▾».
    static let controlRowHeight: CGFloat = 36
    static let buttonHeight: CGFloat = 28
    static let menuWidth: CGFloat = Metrics.PopupMenu.listMenuWidth
    static let font = NSFont.systemFont(ofSize: 14)
    static let smallFont = NSFont.systemFont(ofSize: 12)
}

/// Кнопка окна: значок, текст и «▾» («Приоритет ▾», «Содержит ▾», «И ▾»), подложка под мышью, рамка у значения.
@MainActor
final class PanelButton: NSView {
    var title: String { didSet { needsDisplay = true; setAccessibilityLabel(title) } }
    var icon: String?
    var showsArrow: Bool
    var isBordered: Bool
    var isPlaceholder = false { didSet { needsDisplay = true } }
    var onPress: ((PanelButton) -> Void)?
    private var isHovered = false { didSet { needsDisplay = true } }

    init(title: String, icon: String? = nil, showsArrow: Bool = true, bordered: Bool = false, identifier: String? = nil) {
        self.title = title
        self.icon = icon
        self.showsArrow = showsArrow
        isBordered = bordered
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.popUpButton)
        setAccessibilityLabel(title)
        if let identifier { setAccessibilityIdentifier(identifier) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    /// Ширина по содержимому.
    var fittingWidth: CGFloat {
        var width: CGFloat = 16
        if icon != nil { width += 18 + (title.isEmpty ? 0 : 4) }
        width += ceil((title as NSString).size(withAttributes: [.font: PanelMetrics.font]).width)
        if showsArrow { width += 14 }
        return width
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 0.5, dy: 0.5)
        let radius = Metrics.PopupMenu.rowCornerRadius
        if isHovered {
            Palette.hoverBackground.setFill()
            NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius).fill()
        }
        if isBordered {
            Palette.searchFieldBorder.setStroke()
            NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius).stroke()
        }
        var x: CGFloat = 8
        if let icon {
            ActionMenuIcon.draw(icon, color: Palette.textSecondary, in: NSRect(x: x, y: (bounds.height - 16) / 2, width: 16, height: 16), inkSide: 14)
            x += 18 + (title.isEmpty ? 0 : 4)
        }
        let arrowWidth: CGFloat = showsArrow ? 14 : 0
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let color = isPlaceholder ? Palette.placeholder : Palette.textPrimary
        NSAttributedString(string: title, attributes: [.font: PanelMetrics.font, .foregroundColor: color, .paragraphStyle: paragraph])
            .draw(in: NSRect(x: x, y: (bounds.height - 18) / 2, width: max(0, bounds.width - x - 8 - arrowWidth), height: 18))
        if showsArrow {
            ActionMenuIcon.draw("chevron.down", color: Palette.textSecondary,
                                in: NSRect(x: bounds.maxX - 8 - 10, y: (bounds.height - 10) / 2, width: 10, height: 10), inkSide: 8)
        }
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
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?(self) }
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?(self)
        return true
    }
}

/// Синяя ссылка справа от подписи («Скрыть все», «Показать все»).
@MainActor
final class PanelLinkButton: NSButton {
    var onPress: (() -> Void)?

    init(title: String, identifier: String? = nil) {
        super.init(frame: .zero)
        isBordered = false
        attributedTitle = NSAttributedString(string: title, attributes: [.font: PanelMetrics.smallFont, .foregroundColor: Palette.focusRing])
        target = self
        action = #selector(pressed)
        if let identifier { setAccessibilityIdentifier(identifier) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    var fittingWidth: CGFloat { ceil(attributedTitle.size().width) + 4 }

    @objc private func pressed() { onPress?() }
}

/// Значок-кнопка (глаз, ✕, «•••»): серый символ, подложка под мышью.
@MainActor
final class PanelIconButton: NSView {
    var symbol: String { didSet { needsDisplay = true } }
    var onPress: (() -> Void)?
    private var isHovered = false { didSet { needsDisplay = true } }

    init(symbol: String, label: String, identifier: String? = nil) {
        self.symbol = symbol
        super.init(frame: .zero)
        toolTip = label
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
        if let identifier { setAccessibilityIdentifier(identifier) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered {
            Palette.hoverBackground.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        }
        ActionMenuIcon.draw(symbol, color: Palette.textSecondary, in: NSRect(x: (bounds.width - 16) / 2, y: (bounds.height - 16) / 2, width: 16, height: 16),
                            inkSide: 14)
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
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}

/// Ручка «⠿»: нажатие начинает перетаскивание строки.
@MainActor
final class DragHandleView: NSView {
    var onDrag: ((NSEvent) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        toolTip = "Перетащите, чтобы переставить"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override func draw(_ dirtyRect: NSRect) {
        ActionMenuIcon.draw("circle.grid.2x3.fill", color: Palette.handleIcon,
                            in: NSRect(x: (bounds.width - 12) / 2, y: (bounds.height - 14) / 2, width: 12, height: 14), inkSide: 12)
    }

    override func mouseDown(with event: NSEvent) { onDrag?(event) }
}

/// Строка из кусков слева направо: ширина по месту, по содержимому или остаток; по высоте — по центру.
@MainActor
final class PanelHStack: NSView {
    enum Width { case fixed(CGFloat), flexible }

    private var items: [(view: NSView, width: Width, height: CGFloat?)] = []
    var spacing: CGFloat = 6
    var leading: CGFloat = PropertyPopupMetrics.padding - PropertyPopupMetrics.inset
    var trailing: CGFloat = PropertyPopupMetrics.padding - PropertyPopupMetrics.inset

    override var isFlipped: Bool { true }

    /// `height` — своя высота куска (иначе вся высота строки).
    func add(_ view: NSView, _ width: Width, height: CGFloat? = PanelMetrics.buttonHeight) {
        items.append((view, width, height))
        addSubview(view)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let fixed = items.reduce(CGFloat(0)) { sum, item in if case .fixed(let width) = item.width { sum + width } else { sum } }
        let flexibleCount = items.filter { if case .flexible = $0.width { true } else { false } }.count
        let gaps = spacing * CGFloat(max(items.count - 1, 0))
        let rest = max(0, bounds.width - leading - trailing - fixed - gaps) / CGFloat(max(flexibleCount, 1))
        var x = leading
        for item in items {
            let width: CGFloat = if case .fixed(let value) = item.width { value } else { rest }
            let height = min(item.height ?? bounds.height, bounds.height)
            item.view.frame = NSRect(x: x, y: ((bounds.height - height) / 2).rounded(), width: width, height: height)
            x += width + spacing
        }
    }
}

/// Строка «название — переключатель» («Скрывать пустые группы», «Переносить весь текст»).
@MainActor
final class PanelToggleRow: NSView {
    let title: String
    private(set) var isOn: Bool
    var onToggle: ((Bool) -> Void)?
    private var isHovered = false { didSet { needsDisplay = true } }

    init(title: String, isOn: Bool, identifier: String? = nil) {
        self.title = title
        self.isOn = isOn
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(title)
        setAccessibilityValue(isOn ? 1 : 0)
        if let identifier { setAccessibilityIdentifier(identifier) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    private var itemRect: NSRect { NSRect(x: 0, y: 0, width: bounds.width, height: min(bounds.height, Metrics.ActionMenu.highlightHeight)) }

    override func draw(_ dirtyRect: NSRect) {
        let padding = PropertyPopupMetrics.padding
        if isHovered {
            Palette.hoverBackground.setFill()
            NSBezierPath(roundedRect: itemRect, xRadius: Metrics.PopupMenu.rowCornerRadius, yRadius: Metrics.PopupMenu.rowCornerRadius).fill()
        }
        let track = NSRect(x: bounds.maxX - padding - 30, y: ((itemRect.height - 18) / 2).rounded(), width: 30, height: 18)
        (isOn ? Palette.focusRing : Palette.switchOff).setFill()
        NSBezierPath(roundedRect: track, xRadius: track.height / 2, yRadius: track.height / 2).fill()
        let knob = track.height - 4
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: isOn ? track.maxX - 2 - knob : track.minX + 2, y: track.minY + 2, width: knob, height: knob)).fill()
        let style = Typography.popupMenuTitle
        NSAttributedString(string: title, attributes: [.font: style.font, .foregroundColor: Palette.textPrimary])
            .draw(in: NSRect(x: padding, y: (itemRect.height - style.lineHeight) / 2, width: max(0, track.minX - 2 * padding), height: style.lineHeight))
    }

    func press() {
        isOn.toggle()
        setAccessibilityValue(isOn ? 1 : 0)
        needsDisplay = true
        onToggle?(isOn)
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

    override func accessibilityPerformPress() -> Bool {
        press()
        return true
    }
}

/// Подпись раздела слева и ссылка справа («Показаны в таблице · Скрыть все», «Группы · Скрыть все»).
@MainActor
final class PanelCaptionRow: NSView {
    private let caption: PropertyPopupCaption
    private let link: PanelLinkButton?

    init(_ text: String, link: PanelLinkButton? = nil) {
        caption = PropertyPopupCaption(text)
        self.link = link
        super.init(frame: .zero)
        addSubview(caption)
        if let link { addSubview(link) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        caption.frame = bounds
        if let link {
            let width = link.fittingWidth
            link.frame = NSRect(x: bounds.maxX - PropertyPopupMetrics.padding - width, y: (bounds.height - 18) / 2, width: width, height: 18)
        }
    }
}

/// Строка с ручкой: «⠿», значок, название или плашка варианта, кнопка справа (глаз, ✕).
@MainActor
final class PanelHandleRow: NSView {
    enum Label { case text(String, icon: String?), chip(String, OptionColor), muted(String) }

    private let handle = DragHandleView()
    private let label: Label
    private let trailing: PanelIconButton?
    private let showsHandle: Bool
    var onDrag: ((NSEvent) -> Void)? {
        get { handle.onDrag }
        set { handle.onDrag = newValue }
    }

    init(label: Label, trailing: PanelIconButton?, showsHandle: Bool = true, identifier: String? = nil) {
        self.label = label
        self.trailing = trailing
        self.showsHandle = showsHandle
        super.init(frame: .zero)
        handle.isHidden = !showsHandle
        addSubview(handle)
        if let trailing { addSubview(trailing) }
        setAccessibilityElement(true)
        setAccessibilityRole(.row)
        if let identifier { setAccessibilityIdentifier(identifier) }
        switch label {
        case .text(let text, _), .chip(let text, _), .muted(let text): setAccessibilityLabel(text)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    private var height: CGFloat { min(bounds.height, Metrics.ActionMenu.highlightHeight) }

    override func layout() {
        super.layout()
        handle.frame = NSRect(x: 2, y: 0, width: 16, height: height)
        trailing?.frame = NSRect(x: bounds.maxX - PropertyPopupMetrics.padding - 22, y: (height - 22) / 2, width: 22, height: 22)
    }

    override func draw(_ dirtyRect: NSRect) {
        var x: CGFloat = showsHandle ? 22 : PropertyPopupMetrics.padding
        let end = (trailing?.frame.minX ?? bounds.maxX) - 8
        let style = Typography.popupMenuTitle
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        switch label {
        case .text(let text, let icon):
            if let icon {
                ActionMenuIcon.draw(icon, color: Palette.textSecondary, in: NSRect(x: x, y: ((height - 20) / 2).rounded(), width: 20, height: 20))
                x += 20 + Metrics.PopupMenu.iconToTitleSpacing
            }
            NSAttributedString(string: text, attributes: [.font: style.font, .foregroundColor: Palette.textPrimary, .paragraphStyle: paragraph])
                .draw(in: NSRect(x: x, y: (height - style.lineHeight) / 2, width: max(0, end - x), height: style.lineHeight))
        case .muted(let text):
            NSAttributedString(string: text, attributes: [.font: style.font, .foregroundColor: Palette.textSecondary, .paragraphStyle: paragraph])
                .draw(in: NSRect(x: x, y: (height - style.lineHeight) / 2, width: max(0, end - x), height: style.lineHeight))
        case .chip(let text, let color):
            let size = OptionChip.size(for: text)
            OptionChip.draw(title: text, color: color, in: NSRect(x: x, y: ((height - size.height) / 2).rounded(), width: min(size.width, end - x), height: size.height))
        }
    }
}

/// Ведёт строку за ручку до отпускания: синяя черта — место вставки (0…число строк); `nil` — отпущено без движения.
@MainActor
enum RowDrag {
    static func track(rows: [NSView], in container: NSView, startingWith event: NSEvent) -> Int? {
        guard let window = container.window, let first = rows.first?.frame else { return nil }
        var insertion: Int?
        var line: NSView?
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            let y = container.convert(next.locationInWindow, from: nil).y
            let frames = rows.map(\.frame)
            let index = frames.firstIndex { y < $0.midY } ?? frames.count
            insertion = index
            line?.removeFromSuperview()
            let lineY = index < frames.count ? frames[index].minY : (frames.last?.maxY ?? first.minY)
            let view = NSView(frame: NSRect(x: first.minX, y: lineY - 1, width: first.width, height: 2))
            view.wantsLayer = true
            view.layer?.backgroundColor = Palette.dropIndicator.cgColor
            container.addSubview(view)
            line = view
        }
        line?.removeFromSuperview()
        return insertion
    }
}
