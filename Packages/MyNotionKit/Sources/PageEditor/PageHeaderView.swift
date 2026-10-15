import AppKit
import NotesCore
import VisualStyle

/// Шапка страницы над текстом: эмодзи-иконка и название (contracts/visual-style.md, «Страница»). Как в Notion:
/// без иконки при наведении на шапку над названием серая «Добавить иконку»; иконка под мышью подсвечена,
/// щелчок по ней открывает окно выбора (FR-034).
@MainActor
public final class PageHeaderView: NSView, NSTextFieldDelegate {
    let iconView = PageIconView()
    let addIconButton = PageHeaderButton(symbolName: "face.smiling", title: "Добавить иконку", identifier: "add-page-icon")
    let titleField = PageTitleField(string: "")
    var onTitleChange: ((String) -> Void)?
    var onTitleEnter: (() -> Void)?
    /// «Добавить иконку».
    var onAddIcon: (() -> Void)?
    /// Щелчок по иконке.
    var onIconClick: (() -> Void)?

    /// Мышь над шапкой: у страницы без иконки видна «Добавить иконку».
    var isHovered = false {
        didSet { updateAddIconButton() }
    }

    init(page: Page) {
        super.init(frame: .zero)
        iconView.emoji = page.icon
        iconView.onPress = { [weak self] in self?.onIconClick?() }
        addSubview(iconView)
        addIconButton.onPress = { [weak self] in self?.onAddIcon?() }
        addSubview(addIconButton)
        updateAddIconButton()

        let titleStyle = Typography.pageTitle
        titleField.stringValue = page.title
        titleField.font = titleStyle.font
        titleField.textColor = Palette.textPrimary
        let placeholderStyle = NSMutableParagraphStyle()
        placeholderStyle.firstLineHeadIndent = Metrics.Page.emptyHintCaretGap
        titleField.placeholderAttributedString = NSAttributedString(string: Page.untitledTitle, attributes: [
            .font: titleStyle.font, .foregroundColor: Palette.textSecondary, .paragraphStyle: placeholderStyle,
        ])
        titleField.isBordered = false
        titleField.drawsBackground = false
        titleField.focusRingType = .none
        titleField.usesSingleLineMode = false
        titleField.cell?.wraps = true
        titleField.cell?.isScrollable = false
        titleField.lineBreakMode = .byWordWrapping
        titleField.maximumNumberOfLines = 0
        titleField.delegate = self
        titleField.setAccessibilityIdentifier("page-title")
        // Элемент доступности поля — его ячейка: без метки на ней название не находится.
        titleField.cell?.setAccessibilityIdentifier("page-title")
        addSubview(titleField)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    public override var isFlipped: Bool { true }

    private var hasIcon: Bool { iconView.emoji != nil }

    /// Поставить или убрать иконку; высоту шапки пересчитывает текст страницы.
    func setIcon(_ icon: String?) {
        guard icon != iconView.emoji else { return }
        iconView.emoji = icon
        updateAddIconButton()
        needsLayout = true
    }

    private func updateAddIconButton() {
        addIconButton.isHidden = hasIcon || !isHovered
    }

    private var titleTop: CGFloat {
        hasIcon
            ? Metrics.Page.headerTopPadding + Metrics.Page.iconSize + Metrics.Page.iconToTitleSpacing
            : Metrics.Page.headerTopPaddingWithoutIcon
    }

    private func titleHeight(forWidth width: CGFloat) -> CGFloat {
        let fitting = titleField.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height
        return max(fitting ?? 0, Typography.pageTitle.lineHeight)
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        titleTop + titleHeight(forWidth: width) + Metrics.Page.titleToFirstBlockSpacing
    }

    public override func layout() {
        super.layout()
        iconView.frame = NSRect(x: 0, y: Metrics.Page.headerTopPadding, width: Metrics.Page.iconSize, height: Metrics.Page.iconSize)
        titleField.frame = NSRect(x: 0, y: titleTop, width: bounds.width, height: titleHeight(forWidth: bounds.width))
        // Как у Notion: подложка кнопки выступает левее начала названия на поле кнопки.
        let button = Metrics.PageHeaderButton.self
        let width = addIconButton.fittingWidth
        addIconButton.frame = NSRect(x: -button.horizontalPadding + Metrics.Page.emptyHintCaretGap, y: titleTop - button.titleSpacing - button.height,
                                     width: width, height: button.height)
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    public override func mouseEntered(with event: NSEvent) { isHovered = true }
    public override func mouseExited(with event: NSEvent) { isHovered = false }

    func focusTitle() {
        window?.makeFirstResponder(titleField)
        titleField.currentEditor()?.selectedRange = NSRange(location: (titleField.stringValue as NSString).length, length: 0)
    }

    public func controlTextDidChange(_ notification: Notification) {
        onTitleChange?(titleField.stringValue)
        needsLayout = true
    }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        // Enter из названия — в первый блок (contracts/editor-interactions.md, ⌘N).
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        onTitleEnter?()
        return true
    }
}

/// Иконка страницы в квадрате `Metrics.Page.iconSize`: под мышью — подложка, щелчок открывает окно выбора.
@MainActor
final class PageIconView: NSView {
    private let label = NSTextField(labelWithString: "")
    var onPress: (() -> Void)?

    var emoji: String? {
        didSet {
            label.stringValue = emoji ?? ""
            isHidden = emoji == nil
            setAccessibilityLabel(emoji)
            needsLayout = true
        }
    }

    var isHovered = false { didSet { needsDisplay = true } }

    init() {
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: Metrics.Page.iconFontSize)
        label.alignment = .center
        addSubview(label)
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityIdentifier("page-icon")
        setAccessibilityHelp("Сменить иконку")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        // Строка эмодзи выше и шире квадрата иконки, хотя рисунок в нём помещается: поле по размеру строки
        // с серединой в середине квадрата, иначе рисунок обрезается или съезжает.
        let line = label.intrinsicContentSize
        label.frame = NSRect(x: bounds.midX - line.width / 2, y: bounds.midY - line.height / 2, width: line.width, height: line.height)
    }

    func press() { onPress?() }

    override func accessibilityPerformPress() -> Bool {
        press()
        return true
    }

    /// Эмодзи — подпись самой кнопки; надпись внутри закрывала бы кнопку для доступности.
    override func accessibilityChildren() -> [Any]? { [] }

    /// Щелчок по рисунку — щелчок по иконке, а не по строке эмодзи внутри.
    override func hitTest(_ point: NSPoint) -> NSView? {
        !isHidden && frame.contains(point) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { press() }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isHovered else { return }
        let radius = Metrics.PageHeaderButton.iconHoverCornerRadius
        Palette.hoverBackground.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }
}

/// Серая кнопка шапки со значком и надписью, как «Add icon» у Notion; под мышью — подложка.
@MainActor
final class PageHeaderButton: NSView {
    private let symbolName: String
    let title: String
    var onPress: (() -> Void)?
    private var isPointerInside = false { didSet { needsDisplay = true } }

    init(symbolName: String, title: String, identifier: String) {
        self.symbolName = symbolName
        self.title = title
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        setAccessibilityIdentifier(identifier)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    private var titleAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: Typography.popupMenuTitle.fontSize), .foregroundColor: Palette.pageHeaderButton]
    }

    var fittingWidth: CGFloat {
        let metrics = Metrics.PageHeaderButton.self
        let text = ceil(NSAttributedString(string: title, attributes: titleAttributes).size().width)
        return 2 * metrics.horizontalPadding + metrics.iconSize + metrics.iconToTitleSpacing + text
    }

    func press() { onPress?() }

    override func accessibilityPerformPress() -> Bool {
        press()
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isPointerInside = true }
    override func mouseExited(with event: NSEvent) { isPointerInside = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { press() }
    }

    override func draw(_ dirtyRect: NSRect) {
        let metrics = Metrics.PageHeaderButton.self
        if isPointerInside {
            Palette.hoverBackground.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: metrics.cornerRadius, yRadius: metrics.cornerRadius).fill()
        }
        let iconCenter = NSPoint(x: metrics.horizontalPadding + metrics.iconSize / 2, y: bounds.midY)
        if let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: metrics.iconSize, weight: .regular)) {
            let scale = min(metrics.iconSize / symbol.size.width, metrics.iconSize / symbol.size.height, 1)
            let size = NSSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
            let tinted = NSImage(size: size, flipped: false) { rect in
                symbol.draw(in: rect)
                Palette.pageHeaderButton.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: NSRect(x: iconCenter.x - size.width / 2, y: (iconCenter.y - size.height / 2).rounded(), width: size.width, height: size.height),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        let text = NSAttributedString(string: title, attributes: titleAttributes)
        let size = text.size()
        text.draw(at: NSPoint(x: metrics.horizontalPadding + metrics.iconSize + metrics.iconToTitleSpacing, y: (bounds.height - size.height) / 2))
    }
}
