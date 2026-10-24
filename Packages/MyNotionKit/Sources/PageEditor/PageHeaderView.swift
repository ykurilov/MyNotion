import AppKit
import NotesCore
import VisualStyle

/// Шапка страницы над текстом: эмодзи-иконка и название (contracts/visual-style.md, «Страница»). Как в Notion:
/// без иконки при наведении на шапку над названием серая «Добавить иконку»; иконка под мышью подсвечена,
/// щелчок по ней открывает окно выбора (FR-034).
/// Места шапки (003, plan.md, Structure Decision): «обложка» — над шапкой у текста страницы (`PageLayout/`),
/// «кнопки» — строка кнопок при наведении над названием (`addButton`), «название», «под названием» (`setUnderTitle`).
/// Пустое место высоты не занимает.
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

    /// Мышь над шапкой: видны доступные кнопки строки, у страницы без иконки — «Добавить иконку».
    var isHovered = false {
        didSet { updateButtons() }
    }
    /// Место «кнопки»: по порядку слева направо; первой — «Добавить иконку».
    private(set) var buttons: [PageHeaderButton] = []
    /// Место «под названием»: виды сверху вниз по `order` и их высоты (у строки базы — свойства и обратные ссылки).
    private(set) var underTitle: [(order: Int, view: NSView, height: CGFloat)] = []
    /// Над шапкой обложка: иконка заходит на неё серединой, без иконки название ближе к обложке (как у Notion).
    var hasCover = false {
        didSet { if hasCover != oldValue { needsLayout = true } }
    }

    init(page: Page) {
        super.init(frame: .zero)
        iconView.emoji = page.icon
        iconView.onPress = { [weak self] in self?.onIconClick?() }
        addSubview(iconView)
        addIconButton.onPress = { [weak self] in self?.onAddIcon?() }
        addIconButton.isAvailable = page.icon == nil
        addButton(addIconButton)

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
        addIconButton.isAvailable = !hasIcon
        updateButtons()
        needsLayout = true
    }

    /// Добавить кнопку в строку кнопок над названием (US1: «Добавить обложку»).
    public func addButton(_ button: PageHeaderButton) {
        buttons.append(button)
        addSubview(button)
        button.onAvailabilityChange = { [weak self] in self?.updateButtons() }
        updateButtons()
    }

    /// Вид в месте «под названием» (US5: строка обратных ссылок; 004: свойства строки базы, `order` −1 — выше);
    /// `nil` — вида с этим `order` нет.
    func setUnderTitle(_ view: NSView?, height: CGFloat, order: Int = 0) {
        if let index = underTitle.firstIndex(where: { $0.order == order }) {
            if underTitle[index].view !== view { underTitle[index].view.removeFromSuperview() }
            underTitle.remove(at: index)
        }
        if let view {
            if view.superview !== self { addSubview(view) }
            underTitle.append((order, view, height))
            underTitle.sort { $0.order < $1.order }
        }
        needsLayout = true
    }

    private var underTitleHeight: CGFloat { underTitle.reduce(0) { $0 + $1.height } }

    private func updateButtons() {
        for button in buttons { button.isHidden = !button.isAvailable || !isHovered }
        needsLayout = true
    }

    /// Верх иконки: с обложкой шапка начинается на половину иконки выше нижнего края обложки (`coverOverlap`).
    private var iconTop: CGFloat { hasCover ? 0 : Metrics.Page.headerTopPadding }

    /// Насколько шапка заходит на обложку.
    var coverOverlap: CGFloat { hasCover && hasIcon ? Metrics.Page.iconSize / 2 : 0 }

    private var titleTop: CGFloat {
        if hasIcon { return iconTop + Metrics.Page.iconSize + Metrics.Page.iconToTitleSpacing }
        return hasCover ? Metrics.Page.headerTopPaddingWithCover : Metrics.Page.headerTopPaddingWithoutIcon
    }

    private func titleHeight(forWidth width: CGFloat) -> CGFloat {
        let fitting = titleField.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height
        return max(fitting ?? 0, Typography.pageTitle.lineHeight)
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        titleTop + titleHeight(forWidth: width) + underTitleHeight + Metrics.Page.titleToFirstBlockSpacing
    }

    public override func layout() {
        super.layout()
        iconView.frame = NSRect(x: 0, y: iconTop, width: Metrics.Page.iconSize, height: Metrics.Page.iconSize)
        titleField.frame = NSRect(x: 0, y: titleTop, width: bounds.width, height: titleHeight(forWidth: bounds.width))
        // Как у Notion: подложка первой кнопки выступает левее начала названия на поле кнопки; скрытые места не занимают.
        let metrics = Metrics.PageHeaderButton.self
        var x = -metrics.horizontalPadding + Metrics.Page.emptyHintCaretGap
        for button in buttons where button.isAvailable {
            button.frame = NSRect(x: x, y: titleTop - metrics.titleSpacing - metrics.height, width: button.fittingWidth, height: metrics.height)
            x += button.fittingWidth + metrics.spacing
        }
        // Подложка строки выступает левее названия на её поле — текст стоит под началом названия (как у кнопок выше).
        var y = titleField.frame.maxY
        for item in underTitle {
            let inset = item.view is BacklinksRow ? Metrics.BacklinksRow.horizontalPadding - Metrics.Page.emptyHintCaretGap : 0
            item.view.frame = NSRect(x: -inset, y: y, width: bounds.width + inset, height: item.height)
            y += item.height
        }
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
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate], owner: self))
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }

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
/// Видна при наведении на шапку, если доступна (`isAvailable`: у страницы с обложкой «Добавить обложку» не нужна).
@MainActor
public final class PageHeaderButton: NSView {
    private let symbolName: String
    public let title: String
    public var onPress: (() -> Void)?
    public var isAvailable = true {
        didSet { if isAvailable != oldValue { onAvailabilityChange?() } }
    }
    var onAvailabilityChange: (() -> Void)?
    private var isPointerInside = false { didSet { needsDisplay = true } }

    public init(symbolName: String, title: String, identifier: String) {
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

    public override var isFlipped: Bool { true }

    private var titleAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: Typography.popupMenuTitle.fontSize), .foregroundColor: Palette.pageHeaderButton]
    }

    var fittingWidth: CGFloat {
        let metrics = Metrics.PageHeaderButton.self
        let text = ceil(NSAttributedString(string: title, attributes: titleAttributes).size().width)
        return 2 * metrics.horizontalPadding + metrics.iconSize + metrics.iconToTitleSpacing + text
    }

    func press() { onPress?() }

    public override func accessibilityPerformPress() -> Bool {
        press()
        return true
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate], owner: self))
    }

    public override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    public override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }

    public override func mouseEntered(with event: NSEvent) { isPointerInside = true }
    public override func mouseExited(with event: NSEvent) { isPointerInside = false }
    public override func mouseDown(with event: NSEvent) {}
    public override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { press() }
    }

    public override func draw(_ dirtyRect: NSRect) {
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
